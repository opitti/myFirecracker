# Session Notes - 2026-04-01

## Objectif de la session

Reprendre le flux multi-VM Firecracker, diagnostiquer les problèmes observés au lancement de deux VM, corriger les scripts bloquants, puis documenter le fonctionnement script par script pour reprise ultérieure.

## Contexte de départ

Le repository contenait déjà :

- une note de session précédente :
  - `/home/olivier/dev/firecracker/SESSION-2026-03-30-firecracker-multivm.md`
- un flux multi-VM basé sur :
  - `/home/olivier/dev/firecracker/multi-vm-explore/run-firecracker.sh`
  - `/home/olivier/dev/firecracker/multi-vm-explore/call-firecracker.sh`
- un flux de reconstruction rootfs basé sur :
  - `/home/olivier/dev/firecracker/script/get-kernel.sh`
  - `/home/olivier/dev/firecracker/multi-vm-explore/apply-rootfs-overlay.sh`

## Problèmes observés pendant la session

### 1. `run-firecracker.sh vm2` semblait bloquée sans sortie

Le premier lancement de VM fonctionnait visiblement, mais le second restait silencieux.

Diagnostic :

- `multi-vm-explore/run-firecracker.sh` prenait un verrou via `multi-vm-explore/state/.lock`
- le script faisait ensuite `exec firecracker` sans relâcher explicitement ce verrou
- le second lancement restait donc bloqué dans la boucle d'attente `acquire_lock()`
- comme cette attente ne produit aucune sortie, l'impression était que la commande "ne faisait rien"

Cause racine :

- verrou non libéré avant remplacement du shell par le process Firecracker

### 2. Le guest restait en `/30` et `/app` n'était pas monté

Dans la VM, les constats fournis étaient :

- `ip addr` montrait `172.16.0.2/30`
- `ip route` ne contenait pas de route par défaut vers `172.16.0.1`
- `lsblk` montrait bien `vdb`
- `blkid` montrait bien que `vdb` avait un filesystem ext4
- `mount | grep /app` ne montrait rien
- `fcnet.service` s'exécutait sans erreur apparente

Cela indiquait :

- le disque applicatif était bien attaché côté host
- le service guest tournait bien
- mais le script guest réellement embarqué dans le rootfs n'était pas la version multi-VM attendue

## Vérifications réalisées

### Vérification du rootfs réellement embarqué

Inspection directe de `ubuntu-24.04.ext4` côté hôte :

- le fichier `/usr/local/bin/fcnet-setup.sh` embarqué dans l'image était encore l'ancienne version
- cette ancienne version configurait l'IP en `/30`
- elle ne montait pas `/dev/vdb` sur `/app`

Conclusion :

- le rootfs reconstruit ne contenait pas effectivement l'overlay multi-VM, malgré l'exécution supposée de `script/get-kernel.sh`

### Vérification du problème d'overlay

Exécution directe de :

- `/home/olivier/dev/firecracker/multi-vm-explore/apply-rootfs-overlay.sh squashfs-root`

Résultat :

- le script échouait sur la création de `squashfs-root/app`

Cause :

- `unsquashfs` produisait une arborescence `squashfs-root` avec des permissions/ownership qui empêchaient certaines écritures en tant qu'utilisateur courant

### Vérification du comportement de `get-kernel.sh`

Constat :

- `script/get-kernel.sh` ne commençait pas par `set -euo pipefail`
- donc un échec de `apply-rootfs-overlay.sh` n'arrêtait pas proprement le flux de reconstruction
- le script pouvait continuer et reconstruire une image ext4 sans avoir injecté l'overlay

Cause racine :

- absence de mode strict
- absence de nettoyage systématique de `squashfs-root`
- exécution de l'application d'overlay sans `sudo`

## Corrections apportées

### 1. Correction de `multi-vm-explore/run-firecracker.sh`

Fichier modifié :

- `/home/olivier/dev/firecracker/multi-vm-explore/run-firecracker.sh`

Changement apporté :

- ajout d'une libération explicite du verrou avant `exec firecracker`
- suppression du `trap EXIT` juste après cette libération manuelle

Effet recherché :

- permettre le lancement de plusieurs VM sans blocage silencieux sur `state/.lock`

### 2. Correction de `script/get-kernel.sh`

Fichier modifié :

- `/home/olivier/dev/firecracker/script/get-kernel.sh`

Changements apportés :

- ajout de `#!/usr/bin/env bash`
- ajout de `set -euo pipefail`
- calcul explicite de `SCRIPT_DIR` et `ROOT_DIR`
- `cd` systématique à la racine du repo
- nettoyage préalable de `squashfs-root`
- nettoyage explicite des clés SSH intermédiaires
- appel de `apply-rootfs-overlay.sh` avec `sudo`
- amélioration de plusieurs expansions de variables et vérifications finales

Effet recherché :

- si l'overlay échoue, la reconstruction s'arrête
- le rootfs final ne peut plus être reconstruit silencieusement avec l'ancien script guest
- les artefacts sont générés au bon endroit à la racine du repo

## Documentation ajoutée pendant la session

Un sous-répertoire de documentation a été créé et complété dans :

- `/home/olivier/dev/firecracker/multi-vm-explore/doc`

Documents ajoutés :

- `/home/olivier/dev/firecracker/multi-vm-explore/doc/scripts-multi-vm-explication-ligne-par-ligne.md`
- `/home/olivier/dev/firecracker/multi-vm-explore/doc/rootfs-overlay-explication-ligne-par-ligne.md`

Contenu :

- explication détaillée, ligne par ligne, de :
  - `script/get-kernel.sh`
  - `multi-vm-explore/run-firecracker.sh`
  - `multi-vm-explore/call-firecracker.sh`
  - `multi-vm-explore/apply-rootfs-overlay.sh`
  - `multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh`
  - `multi-vm-explore/rootfs-overlay/etc/resolv.conf`
  - `multi-vm-explore/rootfs-overlay/app/.keep`

## État actuel en fin de session

Les correctifs ont été écrits dans les scripts.

Le point important restant est de rejouer proprement la reconstruction du rootfs et le test des VM avec les scripts corrigés.

À ce stade :

- le bug de verrou dans `run-firecracker.sh` a été corrigé
- le bug de reconstruction incomplète du rootfs a été corrigé dans `get-kernel.sh`
- la documentation détaillée a été ajoutée

## Reprise recommandée

### 1. Repartir d'un état host propre

Depuis la racine du repo :

```bash
cd /home/olivier/dev/firecracker
rmdir multi-vm-explore/state/.lock 2>/dev/null || true
```

Selon l'état de la machine, vérifier aussi qu'aucun ancien process Firecracker ou ancienne VM ne traîne encore.

### 2. Reconstruire le rootfs avec le script corrigé

```bash
cd /home/olivier/dev/firecracker
bash script/get-kernel.sh
```

Résultat attendu :

- `ubuntu-24.04.ext4` reconstruit avec l'overlay multi-VM
- `ubuntu-24.04.id_rsa`
- `vmlinux-*`

### 3. Relancer deux VM

Dans deux terminaux séparés, ou en arrière-plan :

```bash
cd /home/olivier/dev/firecracker
./multi-vm-explore/run-firecracker.sh vm1
./multi-vm-explore/run-firecracker.sh vm2
```

Puis, dans un autre terminal :

```bash
cd /home/olivier/dev/firecracker
./multi-vm-explore/call-firecracker.sh vm1
./multi-vm-explore/call-firecracker.sh vm2
```

### 4. Vérifications attendues dans les VM

Dans chaque VM :

```bash
ip addr
ip route
lsblk
mount | grep /app
systemctl status fcnet.service
journalctl -u fcnet.service --no-pager
```

Résultats attendus :

- IP en `/28`
- route par défaut via `172.16.0.1`
- présence de `vdb`
- montage de `/dev/vdb` sur `/app`
- `fcnet.service` exécuté avec succès

## Fichiers les plus importants pour reprendre

Scripts :

- `/home/olivier/dev/firecracker/script/get-kernel.sh`
- `/home/olivier/dev/firecracker/multi-vm-explore/run-firecracker.sh`
- `/home/olivier/dev/firecracker/multi-vm-explore/call-firecracker.sh`
- `/home/olivier/dev/firecracker/multi-vm-explore/apply-rootfs-overlay.sh`
- `/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh`

Documentation :

- `/home/olivier/dev/firecracker/multi-vm-explore/doc/scripts-multi-vm-explication-ligne-par-ligne.md`
- `/home/olivier/dev/firecracker/multi-vm-explore/doc/rootfs-overlay-explication-ligne-par-ligne.md`

Session précédente :

- `/home/olivier/dev/firecracker/SESSION-2026-03-30-firecracker-multivm.md`

Session actuelle :

- `/home/olivier/dev/firecracker/SESSION-2026-04-01-firecracker-multivm.md`

## Décision utilisateur la plus récente

L'utilisateur a demandé à créer un fichier Markdown de cette session pour pouvoir reprendre plus tard.
