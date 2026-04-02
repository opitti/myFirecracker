# get-kernel — fonctionnement du code

Ce programme Rust est la traduction du script shell `script/get-kernel.sh`. Il télécharge et prépare les trois artefacts nécessaires pour démarrer une VM Firecracker : le noyau Linux, le système de fichiers racine (rootfs) Ubuntu, et une paire de clés SSH pour se connecter à la VM.

## Constantes globales

```
BASE_DIR = /home/olivier/dev/firecracker/rust
REPO_DIR = /home/olivier/dev/firecracker
```

Tous les fichiers produits atterrissent dans `BASE_DIR/kernel/`. Le script `apply-rootfs-overlay.sh` est localisé via `REPO_DIR`.

---

## Flux d'exécution (`main`)

```
main()
  ├── resolve_versions()          → VersionInfo { arch, ci_version }
  ├── download_kernel(versions)   → kernel/vmlinux-X.X.XXX
  ├── setup_rootfs(versions)      → kernel/ubuntu-XX.XX.ext4 + kernel/ubuntu-XX.XX.id_rsa
  └── verify()                    → affiche le résultat des vérifications
```

---

## Fonctions

### `resolve_versions() -> VersionInfo`

Détermine deux informations nécessaires à toutes les requêtes S3 :

1. **`arch`** — récupérée via `uname -m` (ex. `x86_64`).
2. **`ci_version`** — obtenue en faisant une requête HEAD sur la page GitHub des releases de Firecracker. GitHub répond avec un redirect `302` vers l'URL de la dernière release (ex. `.../releases/tag/v1.15.0`). On extrait le tag, puis on tronque le dernier composant de version (`v1.15.0` → `v1.15`) pour obtenir le préfixe utilisé dans les chemins S3 de Firecracker CI.

---

### `resolve_s3_latest_key(ci_version, arch, file_prefix, require_suffix, exclude_suffix) -> String`

Interroge le bucket S3 `spec.ccfc.min` avec un préfixe de chemin pour lister les artefacts disponibles. La réponse est du XML S3 dont on extrait toutes les balises `<Key>`.

Les clés sont filtrées par :
- `file_prefix` — préfixe du nom de fichier (`vmlinux-` ou `ubuntu-`)
- `require_suffix` — suffixe obligatoire si fourni (ex. `.squashfs` pour exclure les `.manifest`)
- `exclude_suffix` — suffixe à exclure si fourni (ex. `.config` pour ne pas prendre le fichier de configuration kernel)

Les clés retenues sont triées par numéro de version via `version_sort_key`, et la dernière est retournée.

#### `version_sort_key(s) -> Vec<u64>`

Extrait un tuple numérique depuis un chemin S3 pour permettre un tri `sort -V` :

| Clé S3 | Résultat |
|--------|----------|
| `firecracker-ci/v1.15/x86_64/vmlinux-6.1.155` | `[6, 1, 155]` |
| `firecracker-ci/v1.15/x86_64/ubuntu-24.04.squashfs` | `[24, 4]` |

---

### `download_kernel(versions, dest_dir)`

1. Crée `dest_dir` si nécessaire.
2. Appelle `resolve_s3_latest_key` avec le préfixe `vmlinux-` en excluant `.config`.
3. Télécharge le binaire kernel via `download_file`.

Fichier produit : `kernel/vmlinux-6.1.XXX`

---

### `setup_rootfs(versions, dest_dir)`

Séquence complète de préparation du rootfs :

| Étape | Détail |
|-------|--------|
| Résolution S3 | Cherche la dernière clé `ubuntu-*.squashfs` (exclut `.manifest`) |
| Téléchargement | Sauvegarde sous `ubuntu-XX.XX.squashfs.upstream` |
| Extraction | `sudo rm -rf squashfs-root` puis `unsquashfs ubuntu-XX.XX.squashfs.upstream` |
| Clés SSH | `ssh-keygen -f id_rsa -N ""` — génère une paire sans passphrase |
| Injection | Copie `id_rsa.pub` → `squashfs-root/root/.ssh/authorized_keys` |
| Renommage | `id_rsa` → `ubuntu-XX.XX.id_rsa` |
| Overlay | `sudo apply-rootfs-overlay.sh squashfs-root` (injecte la config réseau guest) |
| Ownership | `sudo chown -R root:root squashfs-root` (requis par `mkfs.ext4 -d`) |
| Image ext4 | `truncate -s 1G ubuntu-XX.XX.ext4` puis `sudo mkfs.ext4 -d squashfs-root -F ubuntu-XX.XX.ext4` |

Fichiers produits :
- `kernel/ubuntu-24.04.squashfs.upstream` — image squashfs originale
- `kernel/ubuntu-24.04.ext4` — image ext4 1 Go avec overlay appliqué
- `kernel/ubuntu-24.04.id_rsa` — clé privée SSH pour se connecter à la VM

---

### `verify(dest_dir)`

Vérifie que les trois artefacts sont présents et valides :

- **Kernel** — vérifie qu'un fichier `vmlinux-*` existe dans `dest_dir`
- **Rootfs** — lance `e2fsck -fn` sur le `.ext4` ; le code de retour indique si le système de fichiers est sain
- **Clé SSH** — vérifie qu'un fichier `*.id_rsa` existe

---

## Helpers internes

### `download_file(url, dest)`
Télécharge `url` avec `reqwest` en mode bloquant et écrit le contenu dans `dest`.

### `run(args, cwd)`
Exécute une commande système dans le répertoire `cwd`. Panique si la commande échoue (équivalent de `set -e` dans bash).

### `glob_latest(dir, predicate) -> Option<PathBuf>`
Liste les fichiers de `dir`, filtre ceux dont le nom satisfait `predicate`, trie par ordre lexicographique et retourne le dernier — équivalent de `ls <pattern> | tail -1`.

---

## Artefacts produits

Tous dans `BASE_DIR/kernel/` :

```
kernel/
├── vmlinux-6.1.155          ← noyau Linux pour Firecracker
├── ubuntu-24.04.squashfs.upstream  ← rootfs upstream brut
├── ubuntu-24.04.ext4        ← rootfs ext4 1G prêt à l'emploi
└── ubuntu-24.04.id_rsa      ← clé privée SSH (root@VM)
```

## Dépendances système requises

Les commandes suivantes doivent être disponibles sur l'hôte :

- `unsquashfs` (paquet `squashfs-tools`)
- `ssh-keygen`
- `mkfs.ext4` (paquet `e2fsprogs`)
- `e2fsck` (paquet `e2fsprogs`)
- `sudo` avec les droits pour `rm`, `chown`, `mkfs.ext4`, et `apply-rootfs-overlay.sh`
