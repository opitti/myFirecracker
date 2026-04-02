# Explication Ligne Par Ligne De L'Overlay Rootfs Multi-VM

Ce document complète la documentation multi-VM en expliquant les éléments suivants :

- `multi-vm-explore/apply-rootfs-overlay.sh`
- `multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh`
- `multi-vm-explore/rootfs-overlay/etc/resolv.conf`
- `multi-vm-explore/rootfs-overlay/app/.keep`

L'objectif est de comprendre comment le rootfs invité est modifié pour devenir compatible avec le flux multi-VM.

## Rôle global de l'overlay

Le rootfs Ubuntu upstream téléchargé par `script/get-kernel.sh` n'est pas suffisant tel quel pour le mode multi-VM.

L'overlay versionné dans `multi-vm-explore/rootfs-overlay/` sert à injecter dans l'image invitée :

- une configuration réseau compatible avec le sous-réseau partagé `172.16.0.0/28`
- une route par défaut vers l'hôte `172.16.0.1`
- un montage automatique du disque applicatif `/dev/vdb` sur `/app`
- un `resolv.conf` statique
- un répertoire `/app` présent dans l'image

Sans cet overlay :

- le guest reste en `/30`
- il n'a pas de route par défaut adaptée au multi-VM
- le disque `appfs` n'est pas monté automatiquement

## Lien avec `get-kernel.sh`

Le point d'intégration principal est dans :

- [script/get-kernel.sh](/home/olivier/dev/firecracker/script/get-kernel.sh)

La ligne importante est :

```bash
sudo ./multi-vm-explore/apply-rootfs-overlay.sh squashfs-root
```

Cela signifie que l'overlay est appliqué au rootfs décompressé avant la reconstruction finale de `ubuntu-24.04.ext4`.

Le flux exact est :

1. téléchargement du rootfs squashfs upstream
2. extraction dans `squashfs-root`
3. application de l'overlay
4. reconstruction de `ubuntu-24.04.ext4`

## 1. `multi-vm-explore/apply-rootfs-overlay.sh`

Fichier source :

- [multi-vm-explore/apply-rootfs-overlay.sh](/home/olivier/dev/firecracker/multi-vm-explore/apply-rootfs-overlay.sh)

### Rôle du script

Ce script copie le contenu de l'overlay dans une arborescence rootfs déjà extraite.

Il ne construit pas lui-même l'image ext4.
Il prépare seulement les fichiers dans le répertoire cible.

### Explication ligne par ligne

`#!/usr/bin/env bash`

- indique une exécution avec `bash`

`set -euo pipefail`

- active le mode strict
- le script s'arrête immédiatement si une étape échoue

`if [ $# -ne 1 ]; then`

- vérifie qu'un seul argument a été fourni
- cet argument doit être le chemin du rootfs cible

`    echo "Usage: $0 <rootfs-dir>" >&2`

- affiche l'usage attendu

`    exit 1`

- arrête le script si l'argument est absent ou en trop

`fi`

- fin du contrôle des arguments

`TARGET_ROOTFS_DIR="$1"`

- stocke le chemin du rootfs cible
- en pratique, ce sera généralement `squashfs-root`

`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`

- récupère le répertoire du script
- ici cela pointe vers `multi-vm-explore`

`OVERLAY_DIR="${SCRIPT_DIR}/rootfs-overlay"`

- définit le répertoire contenant les fichiers d'overlay

`if [ ! -d "${TARGET_ROOTFS_DIR}" ]; then`

- vérifie que le répertoire rootfs cible existe bien

`    echo "Missing rootfs directory: ${TARGET_ROOTFS_DIR}" >&2`

- affiche l'erreur si le répertoire n'existe pas

`    exit 1`

- arrête le script

`fi`

- fin de la validation du répertoire cible

`install -d "${TARGET_ROOTFS_DIR}/usr/local/bin"`

- crée `usr/local/bin` dans le rootfs cible si besoin

`install -d "${TARGET_ROOTFS_DIR}/etc"`

- crée `etc` dans le rootfs cible si besoin

`install -d "${TARGET_ROOTFS_DIR}/app"`

- crée `/app` dans le rootfs cible si besoin

`install -m 0755 "${OVERLAY_DIR}/usr/local/bin/fcnet-setup.sh" \`

- prépare la copie du script guest `fcnet-setup.sh`

`    "${TARGET_ROOTFS_DIR}/usr/local/bin/fcnet-setup.sh"`

- copie ce script dans le rootfs cible avec des permissions d'exécution

`install -m 0644 "${OVERLAY_DIR}/etc/resolv.conf" \`

- prépare la copie du `resolv.conf`

`    "${TARGET_ROOTFS_DIR}/etc/resolv.conf"`

- copie le `resolv.conf` dans le rootfs cible en lecture standard

`install -m 0644 "${OVERLAY_DIR}/app/.keep" \`

- prépare la copie du fichier `.keep`

`    "${TARGET_ROOTFS_DIR}/app/.keep"`

- copie `.keep` dans `/app`
- cela force l'existence du répertoire `/app` dans l'image finale

### Ce que le script fait réellement

Il pose trois éléments dans le rootfs :

- un script guest réseau et montage
- un fichier DNS statique
- un répertoire `/app`

### Ce que le script ne fait pas

Ce script :

- ne touche pas au host
- ne lance pas Firecracker
- ne démarre pas de VM
- ne reconstruit pas l'image ext4 finale

Il ne fait que copier des fichiers dans une arborescence rootfs.

## 2. `rootfs-overlay/usr/local/bin/fcnet-setup.sh`

Fichier source :

- [multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh](/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh)

### Rôle du script

Ce script s'exécute dans la VM invitée.

Il réalise deux tâches :

- configurer le réseau guest
- monter automatiquement le disque applicatif

Il remplace la version historique mono-VM qui ne faisait qu'assigner une IP `/30`.

### Explication ligne par ligne

`#!/usr/bin/env bash`

- exécution avec `bash`

`set -euo pipefail`

- active le mode strict
- le script s'arrête si une étape critique échoue

`# Copyright ...`

- commentaire légal issu du script d'origine Firecracker

`# SPDX-License-Identifier: Apache-2.0`

- commentaire de licence

`# The guest IP is derived from the Firecracker MAC address 06:00:xx:xx:xx:xx.`

- commentaire explicatif
- rappelle que l'adresse IP du guest est déduite de sa MAC

`# For the multi-VM setup, all guests share 172.16.0.0/28 behind the host bridge.`

- commentaire de contexte
- précise que toutes les VM partagent un même sous-réseau `/28`

`NETWORK_MASK_SHORT="${FC_NETWORK_MASK_SHORT:-/28}"`

- définit le masque réseau à utiliser
- par défaut, c'est `/28`
- peut être surchargé par une variable d'environnement

`DEFAULT_GW="${FC_DEFAULT_GW:-172.16.0.1}"`

- définit la passerelle par défaut
- par défaut, c'est l'IP du bridge host

`APP_BLOCK_DEV="${FC_APP_BLOCK_DEV:-/dev/vdb}"`

- définit le disque block qui doit être monté sur `/app`
- par défaut, c'est `/dev/vdb`

`APP_MOUNT_POINT="${FC_APP_MOUNT_POINT:-/app}"`

- définit le point de montage cible
- par défaut, c'est `/app`

`configure_netdev() {`

- début de la fonction de configuration réseau d'une interface

`    local dev="$1"`

- récupère le nom de l'interface à traiter

`    local mac_ip`

- variable locale qui contiendra la partie MAC convertie

`    local ip`

- variable locale qui contiendra l'IP calculée

`    mac_ip="$(ip link show dev "${dev}" \`

- récupère les informations de l'interface réseau

`        | grep link/ether \`

- garde la ligne contenant la MAC

`        | grep -Po "(?<=06:00:)([0-9a-f]{2}:?){4}" \`

- extrait les 4 octets utiles après le préfixe `06:00:`
- exemple :
  - MAC `06:00:ac:10:00:02`
  - partie utile `ac:10:00:02`

`        || true`

- évite de faire échouer le script si aucun motif n'est trouvé

`    )"`

- fin de la récupération de la partie MAC utile

`    if [ -z "${mac_ip}" ]; then`

- si aucune valeur exploitable n'a été trouvée

`        return 0`

- quitte la fonction sans erreur

`    fi`

- fin du test de présence de la MAC exploitable

`    ip="$(printf "%d.%d.%d.%d" $(echo "0x${mac_ip}" | sed "s/:/ 0x/g"))"`

- convertit la partie hexadécimale de la MAC en IPv4 décimale
- exemple :
  - `ac:10:00:02`
  - devient `172.16.0.2`

`    ip addr replace "${ip}${NETWORK_MASK_SHORT}" dev "${dev}"`

- assigne ou remplace l'adresse IP de l'interface
- utilise ici le masque `/28`

`    ip link set "${dev}" up`

- monte l'interface réseau

`    ip route replace default via "${DEFAULT_GW}" dev "${dev}"`

- installe ou remplace la route par défaut
- la passerelle est le bridge host `172.16.0.1`

`}`

- fin de la fonction réseau

`mount_app_disk() {`

- début de la fonction de montage du disque applicatif

`    local dev_path`

- variable locale pour stocker le chemin résolu du disque

`    if [ ! -b "${APP_BLOCK_DEV}" ]; then`

- vérifie que le device block existe réellement

`        return 0`

- si le disque n'existe pas, la fonction sort sans erreur

`    fi`

- fin du test d'existence du disque

`    mkdir -p "${APP_MOUNT_POINT}"`

- crée le point de montage si besoin

`    dev_path="$(readlink -f "${APP_BLOCK_DEV}" || echo "${APP_BLOCK_DEV}")"`

- résout les liens symboliques éventuels du device

`    blkid "${dev_path}" >/dev/null 2>&1 || mkfs.ext4 -F "${dev_path}"`

- teste si un système de fichiers est déjà présent
- si ce n'est pas le cas, formate le disque en ext4

`    if ! mountpoint -q "${APP_MOUNT_POINT}"; then`

- vérifie si `/app` est déjà monté

`        mount "${dev_path}" "${APP_MOUNT_POINT}"`

- monte le disque applicatif sur `/app`

`    fi`

- fin du test de montage

`}`

- fin de la fonction de montage

`main() {`

- début de la fonction principale

`    local dev`

- variable locale pour parcourir les interfaces

`    for dev in /sys/class/net/*; do`

- boucle sur toutes les interfaces réseau visibles dans le guest

`        dev="$(basename "${dev}")"`

- ne garde que le nom de l'interface

`        [ "${dev}" = "lo" ] && continue`

- ignore l'interface loopback

`        configure_netdev "${dev}"`

- configure l'interface réseau courante

`    done`

- fin de la boucle sur les interfaces

`    mount_app_disk`

- tente ensuite de monter le disque applicatif

`}`

- fin de la fonction principale

`main`

- exécute la fonction principale

### Ce que ce script fait réellement dans le guest

Dans l'ordre :

1. il parcourt les interfaces réseau du guest
2. il dérive leur IP depuis la MAC Firecracker
3. il met l'interface en `/28`
4. il installe une route par défaut
5. il vérifie la présence de `/dev/vdb`
6. il le formate si nécessaire
7. il le monte sur `/app`

### Différence majeure avec l'ancienne version

L'ancienne version faisait seulement :

- calcul de l'IP depuis la MAC
- configuration en `/30`
- mise `up` de l'interface

La nouvelle version ajoute :

- un masque `/28`
- la route par défaut
- le support du disque applicatif `/app`

## 3. `rootfs-overlay/etc/resolv.conf`

Fichier source :

- [multi-vm-explore/rootfs-overlay/etc/resolv.conf](/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/etc/resolv.conf)

Contenu :

```text
nameserver 8.8.8.8
```

### Rôle

Ce fichier fournit une résolution DNS statique dans le guest.

### Pourquoi il est dans l'overlay

En mode multi-VM :

- le rootfs système est partagé
- il est monté en lecture seule
- on ne veut plus dépendre d'une modification manuelle post-boot

Ce fichier permet donc à l'image invitée d'avoir un DNS utilisable dès le démarrage.

## 4. `rootfs-overlay/app/.keep`

Fichier source :

- [multi-vm-explore/rootfs-overlay/app/.keep](/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/app/.keep)

### Rôle

Ce fichier est volontairement vide.

Son but est simplement de forcer la présence du répertoire `/app` dans l'image reconstruite.

### Pourquoi il est utile

Un répertoire vide n'est pas toujours préservé dans certains flux de construction.

Le fichier `.keep` garantit que :

- le répertoire `/app` existe dans le rootfs final
- le script guest peut monter `/dev/vdb` sur `/app`

## Résumé global

L'overlay rootfs multi-VM ajoute dans l'image invitée tout ce qui manque au rootfs upstream pour fonctionner dans le modèle actuel :

- une configuration réseau guest adaptée au bridge partagé
- une passerelle par défaut
- un montage automatique du disque applicatif
- un DNS statique
- un point de montage `/app`

Le découpage logique est :

- `apply-rootfs-overlay.sh` : copie les fichiers d'overlay dans le rootfs extrait
- `fcnet-setup.sh` : exécute la logique réseau et disque dans le guest
- `resolv.conf` : fournit le DNS
- `.keep` : garantit l'existence de `/app`

## Point clé à retenir

Le script host `call-firecracker.sh` attache bien un disque `appfs` à la VM, mais le montage sur `/app` n'est pas fait côté host.

Le montage est réalisé dans le guest par `fcnet-setup.sh`.

Donc si `/app` n'est pas monté dans la VM, il faut vérifier :

- que `get-kernel.sh` a bien reconstruit le rootfs
- que l'overlay a bien été appliqué
- que la VM utilise bien le bon `ubuntu-24.04.ext4`
- que `fcnet.service` et `fcnet-setup.sh` se sont bien exécutés au boot
