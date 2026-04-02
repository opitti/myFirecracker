# Explication Ligne Par Ligne Des Scripts Multi-VM

Ce document explique, script par script, le flux multi-VM actuellement présent dans le repository.

Le périmètre couvert est :

- `script/get-kernel.sh`
- `multi-vm-explore/run-firecracker.sh`
- `multi-vm-explore/call-firecracker.sh`

L'objectif est de comprendre :

- ce que chaque script fait
- dans quel ordre ils s'exécutent
- quelles sont leurs entrées et sorties
- pourquoi ils sont nécessaires dans le flux multi-VM

## Vue d'ensemble du flux

Le flux multi-VM se découpe en trois étapes principales :

1. `script/get-kernel.sh` prépare les artefacts communs à toutes les VM.
2. `multi-vm-explore/run-firecracker.sh <vm-id>` prépare l'état host d'une VM et lance le process Firecracker.
3. `multi-vm-explore/call-firecracker.sh <vm-id>` configure cette VM via l'API Firecracker puis déclenche le boot.

En pratique :

- `get-kernel.sh` produit le kernel, le rootfs et la clé SSH.
- `run-firecracker.sh` crée l'état propre à une VM donnée.
- `call-firecracker.sh` attache le réseau, les disques et démarre la VM.

## 1. `script/get-kernel.sh`

Fichier source :

- [script/get-kernel.sh](/home/olivier/dev/firecracker/script/get-kernel.sh)

### Rôle du script

Ce script prépare les artefacts de base utilisés ensuite par le flux multi-VM :

- un kernel Firecracker `vmlinux-*`
- un rootfs ext4 `ubuntu-24.04.ext4`
- une clé privée SSH `ubuntu-24.04.id_rsa`

Ce script n'exécute pas de VM.
Il prépare l'image qui sera ensuite utilisée par les scripts de lancement.

### Explication ligne par ligne

`#!/usr/bin/env bash`

- indique que le script doit être exécuté avec `bash`

`set -euo pipefail`

- `-e` : le script s'arrête dès qu'une commande échoue
- `-u` : le script échoue si une variable non définie est utilisée
- `pipefail` : une pipeline échoue si une commande interne échoue

`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`

- calcule le répertoire contenant le script lui-même
- ici cela pointe vers `.../firecracker/script`

`ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"`

- remonte d'un niveau pour retrouver la racine du repository
- ici cela pointe vers `.../firecracker`

`cd "${ROOT_DIR}"`

- force l'exécution depuis la racine du repo
- c'est important parce que les fichiers générés sont attendus à cet endroit

`ARCH="$(uname -m)"`

- récupère l'architecture de la machine hôte
- exemple : `x86_64` ou `aarch64`

`release_url="https://github.com/firecracker-microvm/firecracker/releases"`

- définit l'URL de base des releases Firecracker

`latest_version="$(basename "$(curl -fsSLI -o /dev/null -w %{url_effective} "${release_url}/latest")")"`

- suit la redirection GitHub `/latest`
- récupère le tag réel de la dernière release
- `basename` garde seulement le dernier segment de l'URL

`CI_VERSION="${latest_version%.*}"`

- enlève le dernier suffixe de la version
- sert à construire le chemin des artefacts CI Firecracker

`latest_kernel_key=$(curl "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/$CI_VERSION/$ARCH/vmlinux-&list-type=2" \`

- interroge le bucket S3 Firecracker CI
- demande la liste des artefacts `vmlinux-*` compatibles avec la version et l'architecture

`    | grep -oP "(?<=<Key>)(firecracker-ci/$CI_VERSION/$ARCH/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \`

- filtre les lignes XML du listing S3
- extrait uniquement les clés qui ressemblent à des kernels `vmlinux-*`

`    | sort -V | tail -1)`

- trie les versions dans l'ordre naturel
- garde la plus récente

`wget "https://s3.amazonaws.com/spec.ccfc.min/${latest_kernel_key}"`

- télécharge le kernel Linux à la racine du repo

`latest_ubuntu_key=$(curl "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/$CI_VERSION/$ARCH/ubuntu-&list-type=2" \`

- même logique que pour le kernel
- cette fois le script cherche le rootfs Ubuntu upstream

`    | grep -oP "(?<=<Key>)(firecracker-ci/$CI_VERSION/$ARCH/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" \`

- filtre les noms de fichiers `ubuntu-XX.XX.squashfs`

`    | sort -V | tail -1)`

- garde la version la plus récente

`ubuntu_version="$(basename "$latest_ubuntu_key" .squashfs | grep -oE '[0-9]+\.[0-9]+')"`

- extrait seulement la version Ubuntu
- exemple : `24.04`

`wget -O ubuntu-$ubuntu_version.squashfs.upstream "https://s3.amazonaws.com/spec.ccfc.min/$latest_ubuntu_key"`

- télécharge le rootfs squashfs upstream
- lui donne un nom local stable du type `ubuntu-24.04.squashfs.upstream`

`sudo rm -rf squashfs-root`

- supprime une ancienne extraction du rootfs si elle existe
- évite de reconstruire à partir d'un contenu sale ou mélangé

`unsquashfs ubuntu-$ubuntu_version.squashfs.upstream`

- décompresse le rootfs squashfs dans le répertoire `squashfs-root`

`rm -f id_rsa id_rsa.pub "ubuntu-$ubuntu_version.id_rsa"`

- nettoie d'anciennes clés locales

`ssh-keygen -f id_rsa -N ""`

- génère une nouvelle paire de clés SSH sans passphrase

`cp -v id_rsa.pub squashfs-root/root/.ssh/authorized_keys`

- ajoute la clé publique dans le rootfs guest
- cela permettra la connexion SSH en tant que `root`

`mv -v id_rsa ./ubuntu-$ubuntu_version.id_rsa`

- renomme la clé privée locale sous le nom attendu par les autres scripts

`sudo ./multi-vm-explore/apply-rootfs-overlay.sh squashfs-root`

- applique l'overlay multi-VM dans le rootfs extrait
- cette étape injecte notamment :
  - le script guest `fcnet-setup.sh`
  - le `resolv.conf`
  - le répertoire `/app`

`sudo chown -R root:root squashfs-root`

- remet l'arborescence `squashfs-root` sous ownership `root`
- utile avant de reconstruire l'image ext4 finale

`truncate -s 1G ubuntu-$ubuntu_version.ext4`

- crée un fichier image vide de 1 Go
- ce fichier deviendra le rootfs ext4 final

`sudo mkfs.ext4 -d squashfs-root -F ubuntu-$ubuntu_version.ext4`

- formate l'image ext4
- copie dedans le contenu de `squashfs-root`
- produit le fichier final `ubuntu-24.04.ext4`

`echo`

- ajoute une ligne vide dans la sortie

`echo "The following files were downloaded and set up:"`

- affiche un résumé final

`KERNEL="$(ls vmlinux-* | tail -1)"`

- récupère le dernier kernel `vmlinux-*` trouvé

`[ -f "$KERNEL" ] && echo "Kernel: $KERNEL" || echo "ERROR: Kernel $KERNEL does not exist"`

- vérifie que le fichier kernel existe

`ROOTFS="$(ls *.ext4 | tail -1)"`

- récupère le dernier fichier ext4 trouvé

`e2fsck -fn "$ROOTFS" &>/dev/null && echo "Rootfs: $ROOTFS" || echo "ERROR: $ROOTFS is not a valid ext4 fs"`

- vérifie que l'image ext4 est valide sans la modifier

`KEY_NAME="$(ls *.id_rsa | tail -1)"`

- récupère le dernier fichier `.id_rsa` trouvé

`[ -f "$KEY_NAME" ] && echo "SSH Key: $KEY_NAME" || echo "ERROR: Key $KEY_NAME does not exist"`

- vérifie que la clé privée SSH existe

### Sorties attendues

Après exécution, les fichiers importants doivent se trouver à la racine du repo :

- `vmlinux-*`
- `ubuntu-24.04.ext4`
- `ubuntu-24.04.id_rsa`

### Ce que le script ne fait pas

Ce script :

- ne crée pas de VM
- ne démarre pas Firecracker
- ne configure pas de réseau host

Il prépare seulement les artefacts communs.

## 2. `multi-vm-explore/run-firecracker.sh`

Fichier source :

- [multi-vm-explore/run-firecracker.sh](/home/olivier/dev/firecracker/multi-vm-explore/run-firecracker.sh)

### Rôle du script

Ce script prépare l'état host d'une microVM donnée, réserve ses ressources locales, puis lance le process Firecracker associé.

Ce script :

- choisit une IP guest libre
- calcule la MAC de la VM
- crée un disque `app-data.ext4` propre à la VM
- crée les métadonnées `vm.env`
- lance Firecracker avec une socket dédiée

Il ne configure pas encore l'instance via l'API.
Cette partie est faite ensuite par `call-firecracker.sh`.

### Explication ligne par ligne

`#!/usr/bin/env bash`

- exécution via `bash`

`set -euo pipefail`

- active le mode strict

`if [ $# -ne 1 ]; then`

- vérifie qu'un seul argument est fourni

`    echo "Usage: $0 <vm-id>" >&2`

- affiche l'usage en cas d'erreur

`    exit 1`

- arrête le script si l'argument manque

`fi`

- fin du bloc de validation

`VM_ID="$1"`

- récupère l'identifiant de la VM
- exemple : `vm1`, `vm2`

`if [[ ! "${VM_ID}" =~ ^[a-zA-Z0-9_-]+$ ]]; then`

- vérifie que l'identifiant ne contient que des caractères autorisés

`    echo "Invalid vm-id: ${VM_ID}" >&2`

- affiche l'erreur si l'identifiant est invalide

`    exit 1`

- arrête le script

`fi`

- fin de la validation du nom de VM

`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`

- calcule le chemin du répertoire `multi-vm-explore`

`ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"`

- remonte à la racine du repo

`STATE_DIR="${SCRIPT_DIR}/state"`

- dossier d'état partagé de l'exploration multi-VM

`VMS_DIR="${STATE_DIR}/vms"`

- dossier contenant les sous-répertoires de chaque VM

`LOCK_DIR="${STATE_DIR}/.lock"`

- répertoire utilisé comme verrou simple

`VM_DIR="${VMS_DIR}/${VM_ID}"`

- répertoire d'état de la VM courante

`META_FILE="${VM_DIR}/vm.env"`

- fichier de métadonnées persistées de cette VM

`API_SOCKET="${VM_DIR}/firecracker.socket"`

- socket API Firecracker dédiée à cette VM

`APPFS="${VM_DIR}/app-data.ext4"`

- disque applicatif dédié à cette VM

`APPFS_SIZE="${APPFS_SIZE:-100M}"`

- taille du disque applicatif
- par défaut : `100M`

`FIRECRACKER_BIN="${ROOT_DIR}/firecracker"`

- chemin attendu du binaire Firecracker

`ROOTFS="${ROOT_DIR}/ubuntu-24.04.ext4"`

- chemin du rootfs commun partagé par toutes les VM

`mkdir -p "${VMS_DIR}"`

- crée le dossier global des VM si besoin

`acquire_lock() {`

- début de la fonction de prise de verrou

`    while ! mkdir "${LOCK_DIR}" 2>/dev/null; do`

- essaie de créer le répertoire `.lock`
- tant qu'il existe déjà, la création échoue

`        sleep 0.1`

- attend 100 ms avant de réessayer

`    done`

- fin de la boucle d'attente

`}`

- fin de la fonction

`release_lock() {`

- début de la fonction de libération du verrou

`    rmdir "${LOCK_DIR}" 2>/dev/null || true`

- supprime le répertoire `.lock`
- ne plante pas si le dossier n'existe plus

`}`

- fin de la fonction

`trap release_lock EXIT`

- demande au shell d'exécuter `release_lock` quand le script sort

`acquire_lock`

- prend le verrou avant d'allouer l'état VM

`if [ ! -x "${FIRECRACKER_BIN}" ]; then`

- vérifie que le binaire Firecracker existe et est exécutable

`    echo "Missing Firecracker binary: ${FIRECRACKER_BIN}" >&2`

- affiche l'erreur en cas d'absence

`    exit 1`

- arrête le script

`fi`

- fin de la vérification du binaire

`if [ ! -f "${ROOTFS}" ]; then`

- vérifie que le rootfs commun existe

`    echo "Missing rootfs: ${ROOTFS}" >&2`

- affiche l'erreur si le rootfs est absent

`    exit 1`

- arrête le script

`fi`

- fin de la vérification du rootfs

`if [ -f "${META_FILE}" ]; then`

- si la VM existe déjà, recharge simplement son état

`    source "${META_FILE}"`

- importe les variables de `vm.env`

`else`

- sinon, on crée une nouvelle VM logique

`    mkdir -p "${VM_DIR}"`

- crée le dossier de cette VM

`    used_ips=" "`

- initialise une chaîne contenant les IP déjà utilisées

`    for env_file in "${VMS_DIR}"/*/vm.env; do`

- parcourt les VM déjà connues

`        [ -f "${env_file}" ] || continue`

- ignore les entrées inexistantes

`        ip="$(grep '^GUEST_IP=' "${env_file}" | cut -d= -f2 || true)"`

- lit la valeur `GUEST_IP` dans chaque `vm.env`

`        if [ -n "${ip}" ]; then`

- si une IP a bien été trouvée

`            used_ips="${used_ips}${ip} "`

- l'ajoute à la liste des IP réservées

`        fi`

- fin du test de présence de l'IP

`    done`

- fin de la boucle de collecte des IP

`    GUEST_IP=""`

- prépare la future IP de la VM

`    for last_octet in $(seq 2 14); do`

- parcourt les IP disponibles de `172.16.0.2` à `172.16.0.14`
- cela correspond au plan d'adressage actuel `/28`

`        candidate_ip="172.16.0.${last_octet}"`

- construit une IP candidate

`        if [[ "${used_ips}" != *" ${candidate_ip} "* ]]; then`

- teste si cette IP est libre

`            GUEST_IP="${candidate_ip}"`

- garde cette IP si elle n'est pas déjà réservée

`            break`

- sort de la boucle au premier match libre

`        fi`

- fin du test d'IP libre

`    done`

- fin de la recherche d'IP libre

`    if [ -z "${GUEST_IP}" ]; then`

- si aucune IP n'a été trouvée

`        echo "No free guest IP left in 172.16.0.0/28" >&2`

- affiche l'erreur

`        exit 1`

- arrête le script

`    fi`

- fin du test de capacité IP

`    GUEST_LAST_OCTET="${GUEST_IP##*.}"`

- extrait le dernier octet de l'IP

`    GUEST_MAC="$(printf '06:00:ac:10:00:%02x' "${GUEST_LAST_OCTET}")"`

- convertit l'octet final en hexadécimal
- construit une MAC cohérente avec l'IP

`    TAP_DEV="fctap${GUEST_LAST_OCTET}"`

- nomme l'interface TAP host associée à cette VM

`    LOGFILE="${VM_DIR}/firecracker.log"`

- chemin du log Firecracker de cette VM

`    KEY_NAME="${ROOT_DIR}/ubuntu-24.04.id_rsa"`

- chemin de la clé privée SSH commune aux VM

`    cat > "${META_FILE}" <<EOF`

- commence l'écriture du fichier `vm.env`

Les lignes suivantes stockent les métadonnées de la VM :

- `VM_ID`
- `VM_DIR`
- `API_SOCKET`
- `ROOTFS`
- `APPFS`
- `APPFS_SIZE`
- `LOGFILE`
- `KEY_NAME`
- `GUEST_IP`
- `GUEST_MAC`
- `GUEST_LAST_OCTET`
- `TAP_DEV`
- `BRIDGE_DEV`
- `HOST_IP`
- `NETWORK_CIDR`
- `NETWORK_MASK_SHORT`

`EOF`

- termine l'écriture de `vm.env`

`fi`

- fin du bloc création ou relecture de la VM

`source "${META_FILE}"`

- recharge les variables de la VM depuis `vm.env`

`if [ ! -f "${APPFS}" ]; then`

- si le disque applicatif n'existe pas encore

`    truncate -s "${APPFS_SIZE}" "${APPFS}"`

- crée le fichier disque à la taille voulue

`    mkfs.ext4 -F "${APPFS}" >/dev/null`

- le formate en ext4

`fi`

- fin de la création du disque applicatif

`rm -f "${API_SOCKET}"`

- supprime une ancienne socket Firecracker si elle traîne

`cat <<EOF`

- affiche un résumé de la VM

Les lignes affichées donnent :

- la socket
- l'IP guest
- la MAC guest
- le disque applicatif

Le rappel final indique que le rootfs doit avoir été reconstruit avec l'overlay multi-VM.

`EOF`

- fin de l'affichage

`release_lock`

- libère explicitement le verrou avant de lancer Firecracker
- cela permet à une autre VM de démarrer sans rester bloquée en attente

`trap - EXIT`

- retire le `trap` de sortie après libération manuelle du verrou

`exec sudo "${FIRECRACKER_BIN}" --api-sock "${API_SOCKET}" --enable-pci`

- remplace le shell courant par le process Firecracker
- le terminal reste donc occupé tant que Firecracker tourne
- le script ne revient pas à la main tant que le process n'est pas arrêté

### Sorties attendues

Le script crée ou utilise :

- `multi-vm-explore/state/vms/<vm-id>/vm.env`
- `multi-vm-explore/state/vms/<vm-id>/firecracker.socket`
- `multi-vm-explore/state/vms/<vm-id>/app-data.ext4`
- `multi-vm-explore/state/vms/<vm-id>/firecracker.log`

### Ce que le script ne fait pas

Ce script :

- ne configure pas encore les devices Firecracker via l'API
- ne fait pas encore le `PUT /boot-source`
- ne fait pas encore le `InstanceStart`

Il prépare et lance seulement le process Firecracker.

## 3. `multi-vm-explore/call-firecracker.sh`

Fichier source :

- [multi-vm-explore/call-firecracker.sh](/home/olivier/dev/firecracker/multi-vm-explore/call-firecracker.sh)

### Rôle du script

Ce script configure une VM déjà lancée côté process Firecracker.

Il :

- relit `vm.env`
- prépare le bridge et le TAP
- attache le kernel
- attache le rootfs
- attache le disque `/app`
- attache le réseau
- démarre effectivement l'instance

### Explication ligne par ligne

`#!/usr/bin/env bash`

- exécution via `bash`

`set -euo pipefail`

- active le mode strict

`if [ $# -ne 1 ]; then`

- vérifie qu'un argument `vm-id` est fourni

`    echo "Usage: $0 <vm-id>" >&2`

- affiche l'usage en cas d'erreur

`    exit 1`

- arrête le script

`fi`

- fin du contrôle des arguments

`VM_ID="$1"`

- récupère l'identifiant de la VM

`if [[ ! "${VM_ID}" =~ ^[a-zA-Z0-9_-]+$ ]]; then`

- valide le format du `vm-id`

`    echo "Invalid vm-id: ${VM_ID}" >&2`

- affiche l'erreur si le format est invalide

`    exit 1`

- arrête le script

`fi`

- fin de la validation du nom

`SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`

- calcule le répertoire `multi-vm-explore`

`ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"`

- remonte à la racine du repo

`VM_DIR="${SCRIPT_DIR}/state/vms/${VM_ID}"`

- retrouve le dossier d'état de la VM

`META_FILE="${VM_DIR}/vm.env"`

- pointe vers les métadonnées de la VM

`if [ ! -f "${META_FILE}" ]; then`

- refuse d'aller plus loin si la VM n'existe pas encore

`    echo "Unknown vm-id: ${VM_ID}" >&2`

- message d'erreur si `vm.env` est absent

`    echo "Start it first with ./run-firecracker.sh ${VM_ID}" >&2`

- indique qu'il faut d'abord lancer `run-firecracker.sh`

`    exit 1`

- arrête le script

`fi`

- fin de la vérification de l'existence de la VM

`source "${META_FILE}"`

- recharge toute la configuration persistée de la VM

`if [ ! -S "${API_SOCKET}" ]; then`

- vérifie que la socket Firecracker est bien prête

`    echo "Firecracker socket not ready: ${API_SOCKET}" >&2`

- affiche l'erreur si la socket n'existe pas encore

`    echo "Start the VM process first with ./run-firecracker.sh ${VM_ID}" >&2`

- rappelle qu'il faut lancer Firecracker avant de configurer la VM

`    exit 1`

- arrête le script

`fi`

- fin de la vérification de la socket

`HOST_IFACE="$(ip -j route list default | jq -r '.[0].dev')"`

- détecte l'interface réseau par défaut de l'hôte
- elle sera utilisée pour le NAT sortant

`KERNEL="${ROOT_DIR}/$(ls "${ROOT_DIR}"/vmlinux* | tail -1 | xargs basename)"`

- récupère le chemin du dernier kernel `vmlinux*` présent à la racine

`KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1"`

- définit les paramètres kernel de base
- `console=ttyS0` envoie la console guest sur le terminal série

`ARCH="$(uname -m)"`

- détecte l'architecture hôte

`if [ "${ARCH}" = "aarch64" ]; then`

- cas particulier pour ARM64

`    KERNEL_BOOT_ARGS="keep_bootcon ${KERNEL_BOOT_ARGS}"`

- ajoute `keep_bootcon` quand nécessaire

`fi`

- fin du cas ARM64

`sudo ip link add name "${BRIDGE_DEV}" type bridge 2>/dev/null || true`

- crée le bridge host s'il n'existe pas déjà

`sudo ip link set "${BRIDGE_DEV}" up`

- monte le bridge

`if ! ip addr show dev "${BRIDGE_DEV}" | grep -q "${HOST_IP}${NETWORK_MASK_SHORT}"; then`

- vérifie si l'adresse IP du bridge est déjà présente

`    sudo ip addr add "${HOST_IP}${NETWORK_MASK_SHORT}" dev "${BRIDGE_DEV}" 2>/dev/null || true`

- ajoute l'IP du bridge si besoin

`fi`

- fin de la configuration de l'IP du bridge

`sudo ip tuntap add dev "${TAP_DEV}" mode tap 2>/dev/null || true`

- crée l'interface TAP de cette VM si elle n'existe pas déjà

`sudo ip link set "${TAP_DEV}" master "${BRIDGE_DEV}"`

- attache le TAP au bridge

`sudo ip link set "${TAP_DEV}" up`

- monte l'interface TAP

`sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"`

- active le routage IPv4 sur l'hôte

`sudo iptables -P FORWARD ACCEPT`

- autorise le forwarding des paquets

`sudo iptables -t nat -C POSTROUTING -s "${NETWORK_CIDR}" -o "${HOST_IFACE}" -j MASQUERADE 2>/dev/null \`

- vérifie si la règle NAT existe déjà

`    || sudo iptables -t nat -A POSTROUTING -s "${NETWORK_CIDR}" -o "${HOST_IFACE}" -j MASQUERADE`

- ajoute la règle NAT si elle est absente
- cela permet aux VM de sortir sur le réseau via l'hôte

`sudo curl -X PUT --unix-socket "${API_SOCKET}" \`

- commence un appel API Firecracker via la socket Unix

Bloc `logger` :

- configure le fichier de log de cette VM
- demande un niveau `Debug`
- demande l'affichage du niveau et de l'origine des logs

`"http://localhost/logger"`

- endpoint API Firecracker pour la configuration du logger

`sudo curl -X PUT --unix-socket "${API_SOCKET}" \`

- nouveau `PUT` sur l'API

Bloc `boot-source` :

- envoie le chemin du kernel
- envoie les boot args kernel

`"http://localhost/boot-source"`

- endpoint API pour la source de boot

`sudo curl -X PUT --unix-socket "${API_SOCKET}" \`

- nouveau `PUT` sur l'API

Bloc `drives/rootfs` :

- attache `ROOTFS`
- le marque comme disque racine
- le met en lecture seule

`"http://localhost/drives/rootfs"`

- endpoint API pour le disque racine

`sudo curl -X PUT --unix-socket "${API_SOCKET}" \`

- nouveau `PUT` sur l'API

Bloc `drives/appfs` :

- attache le disque `APPFS`
- le laisse en lecture/écriture
- ce disque est destiné à être monté sur `/app` dans le guest

`"http://localhost/drives/appfs"`

- endpoint API pour le disque applicatif

`sudo curl -X PUT --unix-socket "${API_SOCKET}" \`

- nouveau `PUT` sur l'API

Bloc `network-interfaces/net1` :

- attache l'interface réseau de la VM
- fournit la MAC guest
- indique quel TAP host utiliser

`"http://localhost/network-interfaces/net1"`

- endpoint API pour la carte réseau

`sleep 0.015s`

- petite temporisation avant l'ordre de démarrage

`sudo curl -X PUT --unix-socket "${API_SOCKET}" \`

- dernier appel API

Bloc `actions` :

- envoie `InstanceStart`
- c'est cet appel qui démarre réellement la VM

`"http://localhost/actions"`

- endpoint API de commande d'action

`cat <<EOF`

- affiche un résumé final

Les lignes affichées donnent :

- la socket
- le bridge
- le TAP
- l'IP guest
- la MAC guest
- le disque applicatif

Le rappel final indique à nouveau que le rootfs doit être compatible multi-VM.

`EOF`

- fin de l'affichage du résumé

### Ce que le script fait réellement au niveau logique

Dans l'ordre :

1. il vérifie que la VM existe
2. il vérifie que Firecracker tourne déjà
3. il prépare la connectivité host
4. il configure Firecracker par appels API
5. il lance effectivement la VM

### Ce que le script ne fait pas

Ce script :

- ne reconstruit pas le rootfs
- ne crée pas le disque `app-data.ext4`
- ne choisit pas l'adresse IP de la VM

Ces tâches ont déjà été faites avant.

## Résumé global

Les trois scripts s'enchaînent ainsi :

1. `script/get-kernel.sh`
2. `multi-vm-explore/run-firecracker.sh vm1`
3. `multi-vm-explore/call-firecracker.sh vm1`

Puis de nouveau :

1. `multi-vm-explore/run-firecracker.sh vm2`
2. `multi-vm-explore/call-firecracker.sh vm2`

Le découpage important est le suivant :

- `get-kernel.sh` : build et préparation des artefacts communs
- `run-firecracker.sh` : allocation et lancement du process Firecracker
- `call-firecracker.sh` : configuration API et démarrage effectif de la VM

## Fichiers produits et utilisés

Fichiers communs à toutes les VM, placés à la racine du repo :

- `vmlinux-*`
- `ubuntu-24.04.ext4`
- `ubuntu-24.04.id_rsa`

Fichiers propres à chaque VM :

- `multi-vm-explore/state/vms/<vm-id>/vm.env`
- `multi-vm-explore/state/vms/<vm-id>/firecracker.socket`
- `multi-vm-explore/state/vms/<vm-id>/app-data.ext4`
- `multi-vm-explore/state/vms/<vm-id>/firecracker.log`

## Point clé à retenir

Le flux multi-VM repose sur une séparation claire :

- le rootfs système est partagé et monté en lecture seule
- le disque `/app` est propre à chaque VM
- l'état de chaque VM est stocké dans son propre sous-répertoire
- le boot effectif se fait seulement quand `call-firecracker.sh` envoie `InstanceStart`
