# Explication Simple De La Partie Réseau Host Dans `call-firecracker.sh`

Ce document explique très simplement la partie réseau host de `call-firecracker.sh`.

L'objectif est de comprendre :

- ce que fait chaque commande
- pourquoi elle est nécessaire
- dans quel ordre elle agit
- quels fichiers il faut lire pour comprendre encore mieux

## Fichier principal à lire

Le fichier principal est :

- [call-firecracker.sh](/home/olivier/dev/firecracker/multi-vm-explore/call-firecracker.sh)

Pour le contexte complet, il faut aussi lire :

- [run-firecracker.sh](/home/olivier/dev/firecracker/multi-vm-explore/run-firecracker.sh)
- [fcnet-setup.sh](/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh)
- [scripts-multi-vm-explication-ligne-par-ligne.md](/home/olivier/dev/firecracker/multi-vm-explore/doc/scripts-multi-vm-explication-ligne-par-ligne.md)

## Idée générale

Quand on exécute `call-firecracker.sh`, le script prépare le réseau côté hôte pour que la VM puisse :

- parler au bridge Linux de l'hôte
- parler aux autres VM du même sous-réseau
- utiliser l'hôte comme passerelle
- sortir vers l'extérieur via l'hôte

On peut voir cela comme un petit réseau privé construit sur la machine hôte.

## Schéma mental simple

```text
VM
  -> carte réseau virtuelle Firecracker
  -> interface TAP sur l'hôte
  -> bridge Linux sur l'hôte
  -> interface réseau normale de l'hôte
  -> réseau externe / Internet
```

## La partie du script concernée

Dans [call-firecracker.sh](/home/olivier/dev/firecracker/multi-vm-explore/call-firecracker.sh), la séquence importante est :

```bash
sudo ip link add name "${BRIDGE_DEV}" type bridge 2>/dev/null || true
sudo ip link set "${BRIDGE_DEV}" up
if ! ip addr show dev "${BRIDGE_DEV}" | grep -q "${HOST_IP}${NETWORK_MASK_SHORT}"; then
    sudo ip addr add "${HOST_IP}${NETWORK_MASK_SHORT}" dev "${BRIDGE_DEV}" 2>/dev/null || true
fi

sudo ip tuntap add dev "${TAP_DEV}" mode tap 2>/dev/null || true
sudo ip link set "${TAP_DEV}" master "${BRIDGE_DEV}"
sudo ip link set "${TAP_DEV}" up

sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sudo iptables -P FORWARD ACCEPT
sudo iptables -t nat -C POSTROUTING -s "${NETWORK_CIDR}" -o "${HOST_IFACE}" -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -s "${NETWORK_CIDR}" -o "${HOST_IFACE}" -j MASQUERADE
```

## Explication très simple, ligne par ligne

### 1. Créer le bridge si besoin

```bash
sudo ip link add name "${BRIDGE_DEV}" type bridge 2>/dev/null || true
```

Cette ligne crée un bridge Linux.

Un bridge Linux est comme un petit switch logiciel.
Il sert de point central auquel on va raccorder les interfaces TAP des VM.

Dans ce projet, le bridge s'appelle généralement `fcbr0`.

Le `|| true` veut dire :

- si le bridge existe déjà, on ne casse pas le script
- on ignore juste l'erreur

### 2. Monter le bridge

```bash
sudo ip link set "${BRIDGE_DEV}" up
```

Cette ligne active le bridge.

Un bridge peut exister mais être inactif.
Le mettre `up` revient à dire :

- l'interface est allumée
- elle peut maintenant transporter du trafic

### 3. Vérifier si le bridge a déjà son adresse IP

```bash
if ! ip addr show dev "${BRIDGE_DEV}" | grep -q "${HOST_IP}${NETWORK_MASK_SHORT}"; then
```

Cette ligne vérifie si l'IP attendue est déjà présente sur le bridge.

En pratique, on cherche souvent quelque chose comme :

- `172.16.0.1/28`

Pourquoi cette vérification est utile :

- si le bridge a déjà la bonne IP, on ne la rajoute pas une deuxième fois
- cela évite les erreurs inutiles

### 4. Ajouter l'IP au bridge si besoin

```bash
sudo ip addr add "${HOST_IP}${NETWORK_MASK_SHORT}" dev "${BRIDGE_DEV}" 2>/dev/null || true
```

Cette ligne ajoute l'adresse IP au bridge.

Exemple concret :

- `HOST_IP=172.16.0.1`
- `NETWORK_MASK_SHORT=/28`

Donc le bridge reçoit :

- `172.16.0.1/28`

Cette IP est importante car c'est la passerelle côté hôte.
Dans la VM, la route par défaut pointera vers cette adresse.

### 5. Fin de la condition

```bash
fi
```

Cela ferme simplement la logique :

- si l'IP existe déjà, on ne fait rien
- sinon, on l'ajoute

## Pourquoi le bridge est important

Le bridge joue le rôle du réseau local commun.

C'est lui qui permet :

- à plusieurs VM d'être sur le même sous-réseau
- à chaque VM d'avoir un point d'accès vers l'hôte
- d'utiliser `172.16.0.1` comme passerelle

Sans bridge :

- chaque VM serait isolée
- il n'y aurait pas de réseau local partagé propre

## L'interface TAP de la VM

### 6. Créer l'interface TAP si besoin

```bash
sudo ip tuntap add dev "${TAP_DEV}" mode tap 2>/dev/null || true
```

Cette ligne crée une interface TAP pour cette VM.

Une interface TAP est comme l'extrémité côté hôte du câble réseau virtuel de la VM.

Chaque VM a sa propre TAP.

Exemples :

- `fctap2`
- `fctap3`
- `fctap4`

Le `|| true` veut dire :

- si l'interface existe déjà, le script continue quand même

### 7. Attacher le TAP au bridge

```bash
sudo ip link set "${TAP_DEV}" master "${BRIDGE_DEV}"
```

Cette ligne branche la TAP de la VM sur le bridge.

Image simple :

- le bridge = le switch
- le TAP = le câble de la VM

Cette étape relie la VM au réseau local virtuel.

### 8. Monter la TAP

```bash
sudo ip link set "${TAP_DEV}" up
```

Cette ligne active l'interface TAP.

Sans cela :

- le lien existe
- mais il n'est pas opérationnel

## Le rôle du routage sur l'hôte

### 9. Activer le forwarding IPv4

```bash
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
```

Cette ligne autorise l'hôte Linux à faire transiter des paquets d'une interface à une autre.

Autrement dit :

- l'hôte devient capable de router

Sans cela :

- la VM peut être reliée au bridge
- mais l'hôte ne relaiera pas correctement son trafic vers l'extérieur

## Le rôle d'iptables

### 10. Autoriser le forwarding

```bash
sudo iptables -P FORWARD ACCEPT
```

Cette ligne définit la politique par défaut de la chaîne `FORWARD` à `ACCEPT`.

Pourquoi c'est nécessaire :

- le trafic d'une VM qui traverse l'hôte n'est pas du trafic destiné à l'hôte lui-même
- c'est du trafic transféré
- ce trafic passe donc par la chaîne `FORWARD`

Si cette chaîne refusait le trafic, la VM ne pourrait pas sortir correctement.

### 11. Vérifier si la règle NAT existe déjà

```bash
sudo iptables -t nat -C POSTROUTING -s "${NETWORK_CIDR}" -o "${HOST_IFACE}" -j MASQUERADE 2>/dev/null \
```

Cette ligne vérifie si une règle NAT existe déjà.

Elle cible :

- le trafic source venant du réseau des VM, par exemple `172.16.0.0/28`
- le trafic qui sort par l'interface réelle de l'hôte, par exemple `eth0` ou `wlan0`

### 12. Ajouter la règle NAT si elle n'existe pas

```bash
|| sudo iptables -t nat -A POSTROUTING -s "${NETWORK_CIDR}" -o "${HOST_IFACE}" -j MASQUERADE
```

Si la règle n'existe pas, cette ligne l'ajoute.

Le `MASQUERADE` veut dire :

- quand une VM sort sur le réseau externe
- l'hôte remplace l'IP source privée de la VM par sa propre IP de sortie

Exemple :

- la VM envoie un paquet depuis `172.16.0.3`
- ce paquet sort vers Internet par `eth0`
- l'hôte remplace `172.16.0.3` par son IP réelle

Pourquoi c'est nécessaire :

- les IP `172.16.0.x` sont privées
- elles ne sont généralement pas routables telles quelles à l'extérieur
- le NAT permet à la VM de sortir en utilisant l'hôte comme intermédiaire

## Résumé ultra simple de cette séquence

Cette partie de `call-firecracker.sh` fait 5 grandes choses :

1. elle crée un bridge Linux local
2. elle donne au bridge l'IP de passerelle `172.16.0.1/28`
3. elle crée une interface TAP pour la VM et la branche au bridge
4. elle autorise l'hôte à router les paquets
5. elle active le NAT pour que la VM puisse sortir via l'hôte

## Ce que cette partie ne fait pas

Cette partie ne configure pas directement l'IP dans la VM avec une commande exécutée dans le guest.

À la place :

- `run-firecracker.sh` choisit l'IP de la VM
- `run-firecracker.sh` en déduit la MAC de la VM
- `call-firecracker.sh` attache cette MAC à l'interface réseau Firecracker
- `fcnet-setup.sh` dans le guest reconstruit ensuite l'IP à partir de la MAC

## Les variables importantes à suivre

Pour bien comprendre cette partie, il faut suivre ces variables :

- `BRIDGE_DEV`
  - nom du bridge Linux
  - souvent `fcbr0`

- `HOST_IP`
  - IP du bridge côté hôte
  - souvent `172.16.0.1`

- `NETWORK_MASK_SHORT`
  - masque CIDR court
  - ici `/28`

- `NETWORK_CIDR`
  - plage réseau complète des VM
  - ici `172.16.0.0/28`

- `TAP_DEV`
  - interface TAP propre à une VM

- `HOST_IFACE`
  - interface réseau réelle de sortie de l'hôte
  - par exemple `eth0`, `ens3` ou `wlan0`

## Les fichiers à lire pour comprendre encore mieux

### 1. `run-firecracker.sh`

Lire :

- [run-firecracker.sh](/home/olivier/dev/firecracker/multi-vm-explore/run-firecracker.sh)

Pourquoi :

- c'est là que sont décidés `GUEST_IP`, `GUEST_MAC`, `TAP_DEV`, `BRIDGE_DEV`, `HOST_IP` et `NETWORK_CIDR`
- cela permet de comprendre d'où viennent les variables utilisées ensuite dans `call-firecracker.sh`

### 2. `call-firecracker.sh`

Lire :

- [call-firecracker.sh](/home/olivier/dev/firecracker/multi-vm-explore/call-firecracker.sh)

Pourquoi :

- c'est là que le bridge, la TAP, le forwarding et le NAT sont mis en place
- c'est aussi là que Firecracker reçoit la configuration de l'interface réseau avec la MAC de la VM

### 3. `fcnet-setup.sh`

Lire :

- [fcnet-setup.sh](/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh)

Pourquoi :

- c'est ce script dans le guest qui lit la MAC et reconstruit l'IP
- c'est lui qui configure l'interface réseau de la VM
- c'est aussi lui qui ajoute la route par défaut vers `172.16.0.1`

### 4. La documentation détaillée déjà présente

Lire :

- [scripts-multi-vm-explication-ligne-par-ligne.md](/home/olivier/dev/firecracker/multi-vm-explore/doc/scripts-multi-vm-explication-ligne-par-ligne.md)

Pourquoi :

- ce document détaille le flux complet
- il permet de remettre cette séquence dans tout le cycle `get-kernel -> run -> call -> boot guest`

## Schéma pas à pas

### Avant `call`

Avant d'exécuter `call-firecracker.sh` :

- `run-firecracker.sh` a déjà choisi une IP libre pour la VM
- `run-firecracker.sh` a déjà calculé la MAC correspondante
- `run-firecracker.sh` a déjà créé le fichier `vm.env`
- le process Firecracker a déjà été lancé avec sa socket API
- mais la VM n'est pas encore configurée ni démarrée

Schéma :

```text
Etat avant call

Host:
  - process Firecracker lancé
  - socket API prête
  - vm.env existe
  - IP guest réservée
  - MAC guest calculée

VM:
  - pas encore bootée
  - pas encore de réseau réellement attaché
  - pas encore de disques configurés via l'API
```

### Pendant `call`

Pendant `call-firecracker.sh` :

- le bridge Linux est créé si besoin
- le bridge est monté
- l'IP `172.16.0.1/28` est ajoutée au bridge si besoin
- la TAP de la VM est créée
- la TAP est branchée au bridge
- le forwarding IPv4 est activé
- la règle NAT est vérifiée puis ajoutée si nécessaire
- Firecracker reçoit la configuration du kernel, des disques et de l'interface réseau
- Firecracker reçoit la MAC de la VM
- la VM est démarrée

Schéma :

```text
Etat pendant call

VM virtuelle Firecracker
  -> interface réseau Firecracker avec MAC guest
  -> TAP dédiée sur l'hôte
  -> bridge fcbr0
  -> IP host 172.16.0.1/28 sur le bridge
  -> NAT vers l'interface réelle de l'hôte
```

### Après `call`

Après `call-firecracker.sh` :

- la VM a booté
- dans le guest, `fcnet-setup.sh` lit la MAC de l'interface
- le script guest reconstruit l'IP à partir de cette MAC
- le guest applique son IP, par exemple `172.16.0.3/28`
- le guest ajoute sa route par défaut vers `172.16.0.1`
- le guest peut parler au bridge
- le guest peut atteindre l'extérieur via le NAT de l'hôte

Schéma :

```text
Etat après call

Guest:
  - IP configurée, par exemple 172.16.0.3/28
  - route par défaut via 172.16.0.1

Host:
  - bridge fcbr0 actif
  - TAP active et attachée au bridge
  - forwarding IPv4 actif
  - NAT actif

Résultat:
  - la VM peut joindre l'hôte
  - la VM peut joindre les autres VM du bridge
  - la VM peut sortir vers le réseau externe via l'hôte
```
