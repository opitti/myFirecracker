# Architecture Multi-VM Firecracker

Ce document présente la logique complète du flux multi-VM, de la préparation des artefacts jusqu'au démarrage d'un guest fonctionnel.

Il couvre :

- la préparation du rootfs et du kernel
- le lancement du process Firecracker
- la mise en place du réseau host
- la configuration de la VM via l'API Firecracker
- la configuration automatique dans le guest au boot

---

## Vue d'ensemble

Le flux multi-VM repose sur quatre étapes distinctes, chacune portée par un script différent.

```
script/get-kernel.sh
  └─► rootfs + kernel + clé SSH prêts

multi-vm-explore/run-firecracker.sh <vm-id>
  └─► IP réservée, MAC calculée, disques créés, process Firecracker lancé

multi-vm-explore/call-firecracker.sh <vm-id>
  └─► bridge + TAP prêts, API Firecracker configurée, VM bootée

[dans le guest] fcnet-setup.sh
  └─► IP appliquée, route par défaut installée, /app monté
```

Un point clé du design : **l'IP guest n'est jamais poussée directement dans la VM**. Elle est déduite de la MAC au moment du boot.

---

## Étape 1 — Préparation des artefacts communs (`get-kernel.sh`)

Ce script construit les fichiers partagés par toutes les VM.

### Ce qu'il produit

| Fichier | Rôle |
|--------|------|
| `vmlinux-*` | Kernel Linux que Firecracker utilisera pour booter chaque VM |
| `ubuntu-24.04.ext4` | Disque système Ubuntu partagé, monté en lecture seule par chaque VM |
| `ubuntu-24.04.id_rsa` | Clé privée SSH commune pour se connecter aux VM |

### Comment il fonctionne

1. Interroge les releases GitHub Firecracker pour trouver la dernière version.
2. Interroge le bucket S3 de CI Firecracker pour trouver les artefacts compatibles avec cette version.
3. Télécharge le kernel Linux (`vmlinux-*`) et l'image disque Ubuntu publiée par l'équipe Firecracker.
4. Décompresse l'image disque Ubuntu dans un répertoire temporaire `squashfs-root/` — c'est simplement un dossier qui contient l'arborescence du système Ubuntu (`/etc`, `/usr`, `/bin`, etc.), manipulable comme n'importe quel répertoire local.
5. Génère une paire de clés SSH, copie la clé publique dans `squashfs-root/root/.ssh/authorized_keys` pour pouvoir se connecter aux VM.
6. Ajoute les fichiers de customisation multi-VM dans `squashfs-root/` via `apply-rootfs-overlay.sh` (voir étape 1b).
7. Recompresse `squashfs-root/` en une seule image disque `ubuntu-24.04.ext4` que Firecracker pourra attacher à chaque VM.

L'image disque Ubuntu de départ est publiée par l'équipe Firecracker dans un format compressé (squashfs) optimisé pour la distribution. Ce format n'est pas directement utilisable par Firecracker, qui attend un disque au format ext4 — d'où les étapes de décompression puis de recompression dans un autre format.

### Pourquoi le `set -euo pipefail` est critique ici

Si l'ajout des fichiers de customisation échoue silencieusement (par exemple à cause de permissions sur `squashfs-root/`), le script continuerait et produirait un disque système sans les customisations multi-VM. Avec le mode strict, toute erreur arrête le script immédiatement.

---

## Étape 1b — Personnalisation du disque système (`apply-rootfs-overlay.sh`)

Ce script copie les fichiers de customisation multi-VM dans l'arborescence Ubuntu décompressée (`squashfs-root/`), avant qu'elle soit recompressée en image disque finale.

### Ce qu'il ajoute dans l'arborescence Ubuntu

| Fichier ajouté | Emplacement dans le système Ubuntu | Rôle |
|---------------|-----------------------------------|------|
| `rootfs-overlay/usr/local/bin/fcnet-setup.sh` | `/usr/local/bin/fcnet-setup.sh` | Script lancé au boot pour configurer le réseau et monter `/app` |
| `rootfs-overlay/etc/resolv.conf` | `/etc/resolv.conf` | Configuration DNS statique (serveur 8.8.8.8) |
| `rootfs-overlay/app/.keep` | `/app/.keep` | Garantit l'existence du répertoire `/app` dans l'image finale |

Sans ces ajouts, le disque système Ubuntu ne saurait pas :
- configurer l'IP en `/28` adaptée au bridge multi-VM
- ajouter une route par défaut
- monter `/dev/vdb` sur `/app`

---

## Étape 2 — Lancement du process Firecracker (`run-firecracker.sh`)

Ce script prépare l'état local d'une VM et lance le daemon Firecracker associé.

Il ne démarre pas encore la VM. Il prépare seulement le terrain.

### Ce qu'il fait

#### Allocation d'une IP libre

Le script parcourt les fichiers `state/vms/*/vm.env` existants pour collecter les IP déjà réservées, puis cherche la première IP libre dans la plage `172.16.0.2` à `172.16.0.14`.

```
172.16.0.0/28  ─ sous-réseau complet
172.16.0.1     ─ bridge hôte (fcbr0)
172.16.0.2-14  ─ IP disponibles pour les VM (13 slots)
```

#### Calcul de la MAC à partir de l'IP

La MAC est déterminée mécaniquement depuis l'IP :

```
IP : 172.16.0.3
     └─ dernier octet : 3 (décimal) → 03 (hex)

MAC : 06:00:ac:10:00:03
          └─────────────── encodage de 172.16.0.3 en hex
```

Le préfixe `06:00:` identifie les interfaces Firecracker multi-VM.

Ce couplage IP ↔ MAC est la clef de toute la logique réseau : le guest n'a pas besoin qu'on lui dise son IP, il la retrouve lui-même depuis sa MAC au boot.

#### Nommage du TAP

L'interface TAP host reçoit le même dernier octet que l'IP :

```
IP 172.16.0.3 → TAP fctap3
IP 172.16.0.4 → TAP fctap4
```

#### Création des fichiers d'état

Le script crée le répertoire `state/vms/<vm-id>/` et y écrit le fichier `vm.env` qui persiste toutes les variables :

```
state/vms/<vm-id>/
  ├── vm.env               ← toutes les variables (IP, MAC, TAP, chemins...)
  ├── firecracker.socket   ← socket API Unix (créée par le process Firecracker)
  ├── app-data.ext4        ← disque applicatif propre à cette VM
  └── firecracker.log      ← logs du process Firecracker
```

#### Création du disque applicatif

Si `app-data.ext4` n'existe pas, le script le crée et le formate en ext4 (100 Mo par défaut).

Ce disque sera monté sur `/app` dans le guest. Il est indépendant pour chaque VM.

#### Gestion du verrou

Un seul process peut allouer une IP à la fois. Le verrou est un simple répertoire `state/.lock` (la création atomique d'un répertoire garantit l'exclusion mutuelle sous Linux).

Le verrou est libéré **explicitement avant** l'`exec firecracker`. Sans cette libération, le process Firecracker hériterait du répertoire ouvert et bloquerait le lancement de toute VM suivante.

#### Lancement du process Firecracker

```bash
exec sudo firecracker --api-sock state/vms/<vm-id>/firecracker.socket --enable-pci
```

L'`exec` remplace le shell par le process Firecracker. Le terminal reste occupé tant que Firecracker tourne.

À ce stade, **la VM n'est pas encore démarrée**. Firecracker attend des instructions via sa socket API.

---

## Étape 3 — Configuration host et appel API (`call-firecracker.sh`)

Ce script a deux responsabilités : préparer le réseau côté hôte, puis configurer et démarrer la VM via l'API Firecracker.

### 3a — Préparation du réseau host

#### Architecture réseau

```
VM (guest)
  └── carte réseau virtuelle Firecracker (MAC = 06:00:ac:10:00:XX)
        └── interface TAP host (fctapXX)
              └── bridge Linux (fcbr0, 172.16.0.1/28)
                    └── interface physique host (eth0, wlan0...)
                          └── réseau externe / Internet
```

#### Création du bridge (`fcbr0`)

Le bridge est créé une seule fois et partagé par toutes les VM. C'est le point central du réseau local virtuel.

```bash
sudo ip link add name fcbr0 type bridge
sudo ip link set fcbr0 up
sudo ip addr add 172.16.0.1/28 dev fcbr0
```

L'IP `172.16.0.1` est la passerelle que tous les guests utiliseront.

#### Création et branchement du TAP

Chaque VM dispose de sa propre interface TAP, branchée sur le bridge commun :

```bash
sudo ip tuntap add dev fctapXX mode tap
sudo ip link set fctapXX master fcbr0
sudo ip link set fctapXX up
```

Le TAP est l'extrémité host du câble virtuel reliant le guest au bridge. Firecracker utilise cette interface pour injecter et recevoir les paquets Ethernet de la VM.

#### Activation du routage et du NAT

```bash
echo 1 > /proc/sys/net/ipv4/ip_forward         # hôte devient routeur
iptables -P FORWARD ACCEPT                       # autorise le transit
iptables -t nat -A POSTROUTING \
  -s 172.16.0.0/28 -o eth0 -j MASQUERADE        # NAT sortant
```

Le NAT remplace l'IP source privée `172.16.0.x` par l'IP réelle de l'hôte quand un paquet sort vers l'extérieur. Sans NAT, les paquets des VM seraient rejetés par les équipements réseau intermédiaires.

### 3b — Configuration de la VM via l'API Firecracker

Firecracker expose une API REST sur une socket Unix. Chaque appel `PUT` configure un composant de la VM.

#### Logger

```
PUT /logger
```

Configure le fichier de log et le niveau de verbosité (`Debug`).

#### Source de boot

```
PUT /boot-source
{
  "kernel_image_path": "/chemin/vmlinux-*",
  "boot_args": "console=ttyS0 reboot=k panic=1"
}
```

Pointe vers le kernel. `console=ttyS0` redirige la console guest sur le terminal série visible dans le terminal host.

#### Disque rootfs

```
PUT /drives/rootfs
{
  "path_on_host": "ubuntu-24.04.ext4",
  "is_root_device": true,
  "is_read_only": true
}
```

Le rootfs est **partagé et monté en lecture seule** par toutes les VM. Cela permet de ne stocker qu'une seule copie du système de base et d'éviter toute corruption inter-VM.

#### Disque applicatif

```
PUT /drives/appfs
{
  "path_on_host": "state/vms/<vm-id>/app-data.ext4",
  "is_root_device": false,
  "is_read_only": false
}
```

Ce disque est **propre à chaque VM** et monté en lecture/écriture. Il apparaît comme `/dev/vdb` dans le guest et sera monté sur `/app` par le script guest.

#### Interface réseau

```
PUT /network-interfaces/net1
{
  "iface_id": "net1",
  "guest_mac": "06:00:ac:10:00:XX",
  "host_dev_name": "fctapXX"
}
```

C'est l'appel le plus important pour la configuration réseau :
- `guest_mac` : la MAC calculée depuis l'IP — c'est elle que le guest lira pour reconstruire son IP
- `host_dev_name` : le TAP host sur lequel Firecracker connecte la carte réseau virtuelle

#### Démarrage

```
PUT /actions
{
  "action_type": "InstanceStart"
}
```

Cet appel déclenche le boot effectif de la VM. Après cet appel, le kernel Linux démarre dans le guest.

---

## Étape 4 — Configuration automatique dans le guest (`fcnet-setup.sh`)

Ce script s'exécute à l'intérieur de la VM, lancé automatiquement au démarrage par le service systemd `fcnet.service`. Son rôle est de rendre la VM opérationnelle sans aucune intervention manuelle ni communication avec l'hôte après le boot.

Il fait deux choses très différentes : configurer le réseau, et préparer le disque de données. Ces deux responsabilités sont regroupées dans un seul script parce qu'elles doivent toutes les deux se produire tôt au démarrage, avant que les applications tournent.

### Responsabilité 1 — Configurer le réseau

#### Le problème à résoudre

Quand le guest démarre, il ne sait pas quelle IP il doit utiliser. L'hôte ne lui a pas communiqué cette information directement — l'API Firecracker ne dispose pas d'un mécanisme pour pousser une IP dans le guest.

La seule chose que le guest peut observer par lui-même, c'est l'adresse MAC de sa carte réseau. C'est cette contrainte qui motive tout le design de la configuration réseau.

#### Le mécanisme : lire l'IP dans la MAC

L'hôte a construit la MAC de façon à ce qu'elle encode l'IP (voir étape 2). Le guest n'a donc pas besoin qu'on lui dise son IP — il la calcule depuis sa propre MAC.

```
La MAC vue par le guest : 06:00:ac:10:00:03
                                   └──────── ces 4 octets encodent l'IP en hexadécimal

Conversion :
  ac  (hex) → 172 (décimal)
  10  (hex) → 16
  00  (hex) → 0
  03  (hex) → 3

IP déduite : 172.16.0.3
```

Le préfixe `06:00:` sert d'identifiant : le script ignore toute interface dont la MAC ne commence pas par ce préfixe (par exemple, la loopback ou une éventuelle interface de management). C'est un filtre qui rend le script robuste à la présence de plusieurs interfaces réseau dans le guest.

#### Ce que le script applique concrètement

```bash
ip addr replace 172.16.0.3/28 dev eth0     # assigne l'IP avec le masque /28
ip link set eth0 up                         # active l'interface
ip route replace default via 172.16.0.1    # déclare l'hôte comme passerelle
```

L'utilisation de `replace` plutôt que `add` est intentionnelle : si le script est exécuté une deuxième fois (par exemple après un redémarrage à chaud), il écrase la configuration existante sans erreur au lieu d'échouer sur un doublon.

#### Pourquoi le script boucle sur toutes les interfaces

```bash
for dev in /sys/class/net/*; do
    configure_netdev "${dev}"
done
```

Le script ne suppose pas que l'interface s'appelle `eth0` ou `ens3`. Il parcourt toutes les interfaces présentes et applique la configuration à celle dont la MAC correspond au préfixe `06:00:`. Cela rend le script indépendant du nom que le kernel Linux attribue à l'interface, qui peut varier selon la version du kernel ou la configuration.

---

### Responsabilité 2 — Préparer le disque de données

#### Le problème à résoudre

Chaque VM dispose d'un disque de données dédié, attaché par Firecracker comme second disque (`/dev/vdb`). Ce disque doit être monté sur `/app` pour que les applications de la VM puissent l'utiliser.

Ce montage ne peut pas être décrit dans un `/etc/fstab` statique dans le disque système, car le disque système est **partagé et identique pour toutes les VM**. Il ne peut donc pas contenir des instructions propres à une VM particulière.

C'est pourquoi le montage est fait dynamiquement par `fcnet-setup.sh` au moment du boot.

#### Ce que le script fait concrètement

```bash
# Si /dev/vdb n'existe pas, la fonction s'arrête silencieusement
if [ ! -b /dev/vdb ]; then return 0; fi

# Si le disque n'a jamais été formaté, le formater maintenant
blkid /dev/vdb >/dev/null 2>&1 || mkfs.ext4 -F /dev/vdb

# Monter le disque sur /app si ce n'est pas déjà fait
mountpoint -q /app || mount /dev/vdb /app
```

Le formatage conditionnel (`blkid ... || mkfs.ext4`) gère le cas d'un disque neuf : `app-data.ext4` est créé par `run-firecracker.sh` comme un fichier vide formaté, mais si pour une raison quelconque il était vierge, le script le formate lui-même plutôt que d'échouer.

Le test `mountpoint -q` évite de tenter un double montage si le script venait à être relancé.

#### Pourquoi le disque de données est géré dans le même script que le réseau

Ces deux responsabilités n'ont rien à voir fonctionnellement, mais elles partagent la même contrainte opérationnelle : elles doivent s'exécuter **tôt, au démarrage, avant les applications, et sans intervention humaine**. Les regrouper dans un seul service systemd est plus simple que de gérer deux services avec des dépendances entre eux.

---

### Ce que le script ne fait pas

Le script ne configure pas de pare-feu, ne monte pas d'autres disques, et ne contacte pas l'hôte. Il ne fait que ce qui est strictement nécessaire pour rendre le guest autonome : une IP, une route, un disque de données.

---

## Résumé des responsabilités par script

| Script | Où s'exécute | Responsabilité |
|--------|-------------|----------------|
| `script/get-kernel.sh` | hôte | Télécharge et construit les artefacts communs |
| `multi-vm-explore/apply-rootfs-overlay.sh` | hôte | Injecte les customisations multi-VM dans le rootfs |
| `multi-vm-explore/run-firecracker.sh` | hôte | Réserve les ressources de la VM et lance le daemon Firecracker |
| `multi-vm-explore/call-firecracker.sh` | hôte | Prépare le réseau host et configure la VM via l'API |
| `rootfs-overlay/usr/local/bin/fcnet-setup.sh` | guest | Configure le réseau et monte `/app` au boot |

---

## Où est l'IP à chaque étape ?

| Étape | Qui connaît l'IP | Comment |
|-------|-----------------|---------|
| `run-firecracker.sh` | hôte uniquement | Choisie depuis la plage libre, stockée dans `vm.env` |
| `call-firecracker.sh` | hôte uniquement | La MAC (dérivée de l'IP) est injectée dans l'API |
| boot guest | guest | `fcnet-setup.sh` reconstruit l'IP depuis la MAC |

L'API Firecracker ne reçoit jamais d'IP en paramètre — seulement une MAC. C'est cette indirection MAC→IP qui permet au guest de s'auto-configurer sans communication active de l'hôte.

---

## Fichiers produits par le flux

### Artefacts communs (racine du repo)

- `vmlinux-*` — kernel Linux
- `ubuntu-24.04.ext4` — rootfs partagé
- `ubuntu-24.04.id_rsa` — clé privée SSH

### Artefacts par VM (`state/vms/<vm-id>/`)

- `vm.env` — configuration complète de la VM (IP, MAC, TAP, chemins)
- `firecracker.socket` — socket API Unix du daemon Firecracker
- `app-data.ext4` — disque applicatif propre à cette VM
- `firecracker.log` — logs du process Firecracker

### Interfaces réseau créées sur l'hôte

- `fcbr0` — bridge Linux partagé, IP `172.16.0.1/28`
- `fctap2`, `fctap3`, … — une TAP par VM, branchée sur `fcbr0`

---

## Checklist de vérification dans le guest

Après le boot d'une VM, les points suivants doivent être vrais :

```bash
ip addr          # doit montrer 172.16.0.X/28
ip route         # doit montrer "default via 172.16.0.1"
lsblk            # doit montrer vda (rootfs) et vdb (app-data)
mount | grep /app            # doit montrer vdb monté
systemctl status fcnet.service          # doit être active (exited)
journalctl -u fcnet.service --no-pager  # ne doit pas contenir d'erreur
```

Si `/app` n'est pas monté ou si l'IP est en `/30`, c'est que l'overlay n'a pas été injecté correctement dans le rootfs. Il faut relancer `bash script/get-kernel.sh` depuis un état propre.

---

## Algorithme général de chaque script

### `get-kernel.sh`

```
trouver la dernière version de Firecracker
↓
télécharger le kernel et l'image disque Ubuntu correspondants
↓
décompresser l'image disque dans un répertoire temporaire
↓
ajouter les fichiers de customisation multi-VM dans ce répertoire
↓
recompresser le répertoire en une image disque ext4 utilisable par Firecracker
↓
vérifier que les trois artefacts finaux sont valides (kernel, disque, clé SSH)
```

La logique centrale est une transformation : image compressée officielle → répertoire modifiable → image finale personnalisée.

---

### `apply-rootfs-overlay.sh`

```
vérifier que le répertoire cible existe
↓
pour chaque fichier de l'overlay (script réseau, resolv.conf, .keep) :
    copier le fichier à son emplacement dans le répertoire cible
    avec les bonnes permissions
```

Script de copie pure. Aucune logique conditionnelle, aucun état. Il pose des fichiers, c'est tout.

---

### `run-firecracker.sh`

```
valider l'identifiant de VM fourni en argument
↓
prendre le verrou d'allocation (un seul script à la fois dans cette section)
↓
si la VM existe déjà :
    relire son vm.env
sinon :
    lire les vm.env existants pour collecter les IP déjà prises
    choisir la première IP libre dans 172.16.0.2-14
    en déduire la MAC et le nom du TAP
    écrire le vm.env
↓
libérer le verrou
↓
si le disque app-data n'existe pas : le créer et le formater
↓
supprimer l'ancienne socket Firecracker si elle traîne
↓
remplacer le shell par le process Firecracker
  (le terminal reste occupé, Firecracker attend des appels API)
```

La section sous verrou est volontairement courte : elle ne fait qu'allouer une IP et écrire un fichier. Tout le reste (création du disque, lancement de Firecracker) se fait après la libération du verrou pour ne pas bloquer les autres VM.

---

### `call-firecracker.sh`

```
valider l'identifiant de VM
↓
vérifier que run-firecracker.sh a déjà tourné (vm.env et socket présents)
↓
relire vm.env pour récupérer IP, MAC, TAP, chemins des disques
↓
── côté réseau host ──
créer le bridge fcbr0 s'il n'existe pas, lui donner l'IP 172.16.0.1/28
créer le TAP de cette VM, le brancher sur le bridge
activer le routage IPv4 sur l'hôte
ajouter la règle NAT pour que les VM puissent sortir vers Internet
↓
── côté API Firecracker ──
PUT /logger          → configurer le fichier de log
PUT /boot-source     → indiquer quel kernel utiliser
PUT /drives/rootfs   → attacher le disque système (lecture seule, partagé)
PUT /drives/appfs    → attacher le disque de données (lecture/écriture, propre à cette VM)
PUT /network-interfaces/net1  → attacher la carte réseau avec la MAC de la VM
PUT /actions         → démarrer la VM
```

Ce script a deux phases bien séparées : d'abord préparer l'infrastructure réseau sur l'hôte, ensuite décrire la VM à Firecracker via son API. L'ordre est important — la TAP doit exister avant que Firecracker essaie de l'utiliser.

---

### `fcnet-setup.sh` (s'exécute dans le guest)

```
── configuration réseau ──
pour chaque interface réseau du guest (sauf loopback) :
    lire la MAC de l'interface
    si la MAC commence par 06:00: :
        extraire les 4 octets suivants
        les convertir de hexadécimal en décimal → c'est l'IP
        assigner cette IP avec le masque /28 à l'interface
        activer l'interface
        installer une route par défaut vers 172.16.0.1
↓
── montage du disque de données ──
si /dev/vdb existe :
    si /dev/vdb n'a pas encore de système de fichiers : le formater en ext4
    si /app n'est pas encore monté : monter /dev/vdb sur /app
```

Ce script est entièrement autonome : il ne reçoit aucun paramètre de l'hôte, ne fait aucun appel réseau, et déduit tout ce dont il a besoin depuis ce qu'il peut observer localement (MAC de l'interface, présence ou absence de `/dev/vdb`). C'est le seul script qui s'exécute du côté guest.
