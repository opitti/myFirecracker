# Glossaire réseau Firecracker

Ce document approfondit les notions réseau utilisées dans [`call-firecracker.sh`](/home/olivier/dev/firecracker/call-firecracker.sh) et dans les schémas du projet. L'objectif n'est pas seulement de donner une définition, mais d'expliquer ce que chaque notion fait concrètement dans ton setup Firecracker.

## Contexte global du projet

Dans ton dossier, le montage réseau visé est le suivant :

- le host Linux crée une interface virtuelle `tap0`
- Firecracker connecte la carte réseau virtuelle de la microVM à `tap0`
- le host prend l'adresse `172.16.0.1/30`
- la microVM prend l'adresse `172.16.0.2/30`
- la microVM utilise le host comme passerelle
- le host fait le forwarding et le NAT pour permettre à la microVM de sortir vers Internet

Autrement dit, le host joue deux rôles en même temps :

- il héberge la microVM
- il se comporte comme un petit routeur pour elle

## TAP

Une interface `TAP` est une interface réseau virtuelle de niveau 2, c'est-à-dire au niveau Ethernet.

Ce point est important : une interface Ethernet ne transporte pas seulement des paquets IP. Elle transporte des trames Ethernet complètes, avec notamment :

- une adresse MAC source
- une adresse MAC destination
- une charge utile contenant souvent un paquet IP

Pourquoi c'est utile pour une VM :

- une VM s'attend à avoir une vraie carte réseau
- une vraie carte réseau travaille au niveau Ethernet
- une interface TAP est donc une bonne représentation logicielle de cette carte côté host

Dans ton cas :

- `tap0` est l'extrémité host du lien réseau virtuel
- la microVM a sa propre interface réseau virtuelle
- Firecracker relie les deux

On peut voir `tap0` comme :

- soit un câble Ethernet virtuel
- soit un port réseau virtuel branché sur le host

Exemple concret :

- quand la microVM envoie un paquet vers `172.16.0.1`
- ce paquet sort par `eth0` dans la microVM
- Firecracker le remet sur `tap0` côté host
- le noyau Linux du host reçoit alors ce trafic comme s'il provenait d'une interface réseau ordinaire

Exemple mental simple :

- au lieu d'avoir un câble RJ45 entre deux machines physiques
- tu as ici un lien purement logiciel entre la microVM et le host

## TUN vs TAP

La distinction mérite d'être posée clairement.

Une interface `TUN` travaille au niveau 3 :

- elle transporte directement des paquets IP
- elle ne manipule pas les trames Ethernet complètes

Une interface `TAP` travaille au niveau 2 :

- elle transporte les trames Ethernet
- elle convient mieux quand on veut simuler une vraie carte réseau de machine

Pourquoi Firecracker utilise ici une logique de type TAP :

- la microVM voit une NIC Ethernet
- elle a une MAC
- elle se comporte comme une vraie machine branchée sur un petit réseau local

Exemple pédagogique :

- avec `TUN`, on pense "tunnel IP"
- avec `TAP`, on pense "mini carte Ethernet virtuelle"

## NIC

`NIC` signifie `Network Interface Controller`.

C'est simplement une carte réseau.

Dans une machine physique :

- c'est une carte matérielle ou un contrôleur intégré

Dans une VM :

- c'est une carte virtuelle fournie par l'hyperviseur

Dans ton setup :

- la microVM possède une NIC virtuelle
- Linux dans la microVM la nomme typiquement `eth0`
- cette NIC a une MAC fixée par Firecracker

Exemple concret tiré du script :

```bash
FC_MAC="06:00:AC:10:00:02"
```

Puis :

```bash
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"iface_id\": \"net1\",
        \"guest_mac\": \"$FC_MAC\",
        \"host_dev_name\": \"$TAP_DEV\"
    }" \
    "http://localhost/network-interfaces/net1"
```

Cela veut dire :

- Firecracker crée une interface réseau virtuelle pour la microVM
- cette interface portera la MAC `06:00:AC:10:00:02`
- côté host, elle sera reliée à `tap0`

Exemple de lecture réseau :

- `eth0` dans la microVM n'est pas une vraie carte PCI physique
- c'est une carte virtuelle
- mais pour Linux invité, elle se comporte comme une interface réseau normale

## Host

Le `host` est la machine Linux réelle qui exécute Firecracker.

Dans ton dossier, le host fait beaucoup plus que "faire tourner un programme". Il :

- crée l'interface `tap0`
- configure son adresse IP
- active `ip_forward`
- configure `iptables`
- expose le socket API Firecracker
- sert de passerelle à la microVM

Exemple concret :

- quand la microVM veut joindre `8.8.8.8`
- elle envoie le trafic au host à l'adresse `172.16.0.1`
- le host reçoit le paquet sur `tap0`
- le host décide ensuite de le transférer vers son interface externe

Autrement dit :

- le host est à la fois l'hyperviseur, le premier voisin réseau de la VM et le routeur de sortie

## Guest

Le `guest` est la machine virtuelle elle-même, ici la microVM Firecracker.

Elle a sa propre vision du système :

- son propre noyau
- son propre root filesystem
- sa propre interface réseau `eth0`
- sa propre table de routage

Elle ne "voit" pas directement les interfaces physiques du host.

Exemple concret :

- depuis le guest, `eth0` est l'interface réseau
- depuis le guest, `172.16.0.1` est la passerelle
- depuis le guest, Internet est accessible via cette passerelle

Exemple de commande dans l'invité :

```bash
ip route add default via 172.16.0.1 dev eth0
```

Cette commande n'a de sens que du point de vue du guest. Elle dit :

- "si je ne sais pas où envoyer un paquet, je l'envoie d'abord au host"

## Adresse MAC

Une adresse `MAC` identifie une interface au niveau Ethernet.

Elle n'est pas la même chose qu'une adresse IP :

- la MAC sert sur le lien local
- l'IP sert pour le routage réseau

Exemple :

- MAC : `06:00:AC:10:00:02`
- IP : `172.16.0.2`

Dans ton setup, la MAC est importante pour deux raisons :

- Firecracker en a besoin pour définir la carte réseau virtuelle
- le commentaire du script indique que l'IP du guest est dérivée de cette MAC dans la préparation du rootfs

Exemple pédagogique :

- sur un réseau Ethernet, si une machine veut parler à son voisin local, elle l'identifie par sa MAC
- ensuite, à l'intérieur de la trame Ethernet, on transporte souvent un paquet IP

Mini analogie :

- MAC = identifiant local du port réseau
- IP = adresse logique pour savoir où aller dans le réseau

## Adresse IP

Une adresse IP identifie une machine ou une interface au niveau IP.

Dans ton réseau local privé :

- `172.16.0.1` est l'IP de `tap0` sur le host
- `172.16.0.2` est l'IP de `eth0` dans la microVM

Ce sont ces adresses qui sont utilisées pour :

- faire un `ping`
- faire un `ssh`
- définir la passerelle
- router le trafic

Exemple local :

```bash
ssh -i ubuntu-24.04.id_rsa root@172.16.0.2
```

Ici :

- `172.16.0.2` est l'adresse IP de la microVM
- le host peut la joindre directement parce qu'il est sur le même petit sous-réseau via `tap0`

Exemple externe :

- quand la microVM veut joindre `8.8.8.8`
- `8.8.8.8` n'est pas sur son réseau local
- elle doit donc utiliser sa passerelle `172.16.0.1`

## Pourquoi `172.16.0.1`

Le choix de `172.16.0.1` n'est pas magique. Il est à la fois pratique et cohérent.

Première raison : c'est une adresse privée RFC1918.

Cela veut dire :

- elle est faite pour les réseaux internes
- elle n'est pas destinée à être routée telle quelle sur Internet

Deuxième raison : `.1` est souvent choisie par convention pour la passerelle du réseau.

Dans un réseau simple, on voit souvent :

- routeur ou passerelle : `.1`
- machine voisine : `.2`, `.3`, etc.

Troisième raison : ici le script met en place un mini réseau point-à-point entre deux extrémités seulement :

- host : `172.16.0.1`
- guest : `172.16.0.2`

Exemple pédagogique :

Si tu remplaçais ces valeurs par :

- host : `10.20.30.1`
- guest : `10.20.30.2`

cela fonctionnerait aussi en principe, tant que :

- le sous-réseau est cohérent
- la config du guest suit
- les règles NAT utilisent la bonne interface de sortie

Donc `172.16.0.1` n'est pas obligatoire. C'est un choix simple, propre et classique.

## Masque `/30`

Le `/30` signifie qu'on réserve 30 bits pour la partie réseau et seulement 2 bits pour la partie hôte.

En IPv4, cela produit 4 adresses au total :

- une adresse de réseau
- deux adresses utilisables
- une adresse de broadcast

Pour `172.16.0.0/30`, on obtient :

- `172.16.0.0` : réseau
- `172.16.0.1` : première adresse utilisable
- `172.16.0.2` : deuxième adresse utilisable
- `172.16.0.3` : broadcast

Pourquoi c'est bien adapté ici :

- il n'y a que deux machines logiques à connecter
- le host
- la microVM

Exemple pédagogique :

Si tu utilisais un `/24` comme `172.16.0.1/24`, tu aurais jusqu'à 254 adresses utilisables. Ce ne serait pas faux, mais ce serait bien plus large que nécessaire.

Le `/30` exprime clairement :

- "ce lien ne sert qu'à connecter deux extrémités"

## Réseau, broadcast et adresses utilisables

Ces notions reviennent souvent avec les sous-réseaux.

Adresse de réseau :

- identifie le sous-réseau lui-même
- ici `172.16.0.0`

Adresse de broadcast :

- sert à parler à tous les hôtes du sous-réseau
- ici `172.16.0.3`

Adresses utilisables :

- les vraies adresses que l'on peut affecter aux interfaces
- ici `172.16.0.1` et `172.16.0.2`

Exemple :

- `tap0` ne peut pas prendre `172.16.0.0`
- `eth0` dans la VM ne peut pas prendre `172.16.0.3`
- les seules adresses normales pour ces deux interfaces sont `172.16.0.1` et `172.16.0.2`

## Passerelle

Une `passerelle` ou `gateway` est la machine à laquelle on envoie les paquets destinés à un réseau qu'on ne sait pas joindre directement.

Dans ton setup :

- la microVM connaît directement `172.16.0.1` car c'est son voisin local
- elle ne connaît pas directement `8.8.8.8`
- elle envoie donc ce trafic à sa passerelle : `172.16.0.1`

Exemple concret :

Quand la VM fait :

```bash
ping 8.8.8.8
```

la logique réseau est :

1. `8.8.8.8` n'est pas dans le réseau `172.16.0.0/30`
2. il faut donc utiliser la passerelle
3. la passerelle configurée est `172.16.0.1`
4. le paquet est envoyé au host

Mini analogie :

- ta maison sait envoyer une lettre au bureau de poste local
- le bureau de poste local sait ensuite comment l'acheminer plus loin

Ici :

- la microVM sait parler au host
- le host sait parler au reste du réseau

## Route par défaut

La route par défaut est la règle utilisée quand aucune route plus spécifique ne correspond à la destination.

Dans le script :

```bash
ssh -i $KEY_NAME root@172.16.0.2  "ip route add default via 172.16.0.1 dev eth0"
```

Cela configure la table de routage du guest pour dire :

- tout ce qui n'est pas local doit partir vers `172.16.0.1` via `eth0`

Exemple pédagogique :

Si la VM veut joindre :

- `172.16.0.1` : c'est local, elle envoie directement
- `172.16.0.2` : c'est elle-même
- `8.8.8.8` : ce n'est pas local, elle utilise la route par défaut

Exemple de lecture humaine :

```text
default via 172.16.0.1 dev eth0
```

se lit comme :

- "par défaut, j'envoie tout au host via mon interface `eth0`"

## NAT

`NAT` signifie `Network Address Translation`.

Dans ton cas, le type de NAT utilisé sert surtout à remplacer l'adresse source privée du guest par l'adresse IP du host lorsque le trafic sort vers le réseau externe.

Pourquoi c'est nécessaire :

- la VM utilise une adresse privée `172.16.0.2`
- cette adresse n'est pas routable publiquement sur Internet
- si elle sortait telle quelle, les réponses ne reviendraient pas correctement depuis Internet

Le host fait donc l'intermédiaire.

Exemple avant NAT :

- source : `172.16.0.2`
- destination : `8.8.8.8`

Exemple après NAT sur le host :

- source : adresse externe du host
- destination : `8.8.8.8`

Ensuite, quand la réponse revient :

- le host regarde sa table de NAT
- il comprend que cette réponse correspond à une connexion initiée par `172.16.0.2`
- il retransmet donc le paquet vers la microVM

Exemple mental :

- la VM emprunte l'identité réseau du host pour sortir
- le host garde la mémoire des échanges pour pouvoir rendre les réponses à la bonne VM

## MASQUERADE

`MASQUERADE` est une cible `iptables` pratique pour faire du NAT sortant quand l'adresse IP externe du host peut varier.

Dans ton script :

```bash
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
```

Lecture :

- table `nat`
- chaîne `POSTROUTING`
- pour le trafic qui sort via l'interface externe du host
- remplacer l'adresse source par l'adresse de cette interface

Pourquoi `MASQUERADE` plutôt qu'une règle SNAT fixe :

- c'est plus simple
- c'est adapté aux machines dont l'IP externe peut changer
- typiquement un laptop en Wi-Fi ou une machine derrière DHCP

Exemple :

- si `HOST_IFACE` vaut `wlp2s0`
- tout paquet sortant vers Internet par `wlp2s0` est NATé avec l'IP actuelle de `wlp2s0`

## iptables

`iptables` est l'outil classique de configuration du pare-feu IPv4 et du NAT sous Linux.

Dans ton script, il est utilisé à deux endroits clés :

```bash
sudo iptables -P FORWARD ACCEPT
```

et :

```bash
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
```

Premier effet :

- la politique par défaut de la chaîne `FORWARD` devient `ACCEPT`
- le host accepte donc de relayer les paquets entre interfaces

Deuxième effet :

- le trafic sortant du guest vers l'extérieur est NATé

Exemple pédagogique "sans iptables" :

- la VM envoie un paquet au host
- le host le reçoit
- mais il peut refuser de le transférer ou ne pas le NATer
- résultat : pas d'accès Internet fonctionnel

Exemple "avec iptables" :

- le host accepte le forwarding
- le host NATe le trafic sortant
- la VM peut joindre Internet

Point important :

- `iptables -P FORWARD ACCEPT` modifie la politique globale de forwarding du host
- c'est simple pour un labo local, mais plus agressif qu'une règle ciblée

## `ip_forward`

`ip_forward` est un réglage du noyau Linux qui autorise la machine à transférer des paquets entre interfaces.

Dans ton script :

```bash
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
```

Quand `ip_forward=0` :

- le host se comporte comme une machine terminale
- il reçoit les paquets destinés à lui-même
- mais il ne relaie pas normalement les paquets d'une interface à l'autre

Quand `ip_forward=1` :

- le host peut agir comme routeur

Exemple concret :

- paquet entrant par `tap0`
- paquet destiné à Internet
- le host peut le renvoyer via son interface externe

Sans `ip_forward` :

- le host voit passer le paquet de la VM
- mais il ne le route pas vers l'extérieur

## Interface externe du host

Le script détecte dynamiquement l'interface de sortie du host avec :

```bash
HOST_IFACE=$(ip -j route list default |jq -r '.[0].dev')
```

Cette commande lit la route par défaut du host et en déduit le nom de l'interface utilisée pour sortir.

Exemples possibles :

- `eth0`
- `enp0s31f6`
- `wlp2s0`

Pourquoi cette information est nécessaire :

- la règle `MASQUERADE` doit savoir par quelle interface le trafic sort réellement

Exemple :

Si ton host sort par `wlp2s0`, la règle sera en pratique équivalente à :

```bash
sudo iptables -t nat -A POSTROUTING -o wlp2s0 -j MASQUERADE
```

## RFC1918

`RFC1918` désigne les plages IPv4 réservées aux réseaux privés.

Les trois grandes plages sont :

- `10.0.0.0/8`
- `172.16.0.0/12`
- `192.168.0.0/16`

Pourquoi elles existent :

- permettre d'utiliser des adresses internes sans consommer d'adresses publiques
- séparer les réseaux internes d'Internet

Dans ton cas :

- `172.16.0.1` et `172.16.0.2` sont des adresses privées
- elles sont parfaites pour un petit réseau local host <-> microVM

Exemple pédagogique :

- chez toi, ta box distribue souvent des `192.168.x.x`
- ici, le script choisit du `172.16.x.x`
- l'idée est la même : réseau interne privé

## Socket Unix

Un socket Unix est un point de communication local entre processus, représenté par un fichier spécial.

Dans ton projet :

- Firecracker écoute sur `/tmp/firecracker.socket`
- `call-firecracker.sh` envoie des requêtes d'API avec `curl --unix-socket`

Exemple :

```bash
sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data '{ ... }' \
    "http://localhost/boot-source"
```

Cette commande ressemble à une requête HTTP normale, mais elle ne passe pas par le réseau TCP/IP classique.

Elle passe par le socket Unix local.

Pourquoi c'est utile :

- pas besoin d'ouvrir un port TCP
- communication locale simple entre le script et Firecracker

Exemple de distinction :

- `http://localhost:8080/...` utiliserait un port réseau TCP
- `--unix-socket /tmp/firecracker.socket` utilise un fichier socket local

## Rootfs

Le `rootfs` est le système de fichiers racine de la microVM.

Dans ton dossier, le script choisit un fichier `*.ext4`, par exemple [`ubuntu-24.04.ext4`](/home/olivier/dev/firecracker/ubuntu-24.04.ext4).

Il est attaché à Firecracker avec :

```json
{
  "drive_id": "rootfs",
  "path_on_host": "./ubuntu-24.04.ext4",
  "is_root_device": true,
  "is_read_only": false
}
```

Ce que cela implique :

- pour le host, c'est juste un fichier image
- pour la microVM, c'est son disque racine

Exemple pédagogique :

- quand la microVM modifie `/etc/resolv.conf`
- elle écrit en réalité dans ce système de fichiers invité
- comme `is_read_only` est `false`, l'image peut être modifiée

## `vmlinux`

`vmlinux` désigne ici le noyau Linux fourni à Firecracker pour démarrer la microVM.

Dans ton dossier, le script choisit un fichier commençant par `vmlinux`, par exemple [`vmlinux-6.1.155`](/home/olivier/dev/firecracker/vmlinux-6.1.155).

Exemple de configuration :

```json
{
  "kernel_image_path": "./vmlinux-6.1.155",
  "boot_args": "console=ttyS0 reboot=k panic=1"
}
```

Lecture :

- `kernel_image_path` indique quel noyau démarrer
- `boot_args` donne la ligne de commande du noyau

Exemple de rôle :

- le noyau initialise le matériel virtuel présenté par Firecracker
- monte le rootfs
- lance l'espace utilisateur
- fait apparaître `eth0` dans la microVM

## SSH

`SSH` est le protocole utilisé pour ouvrir une session distante sécurisée.

Dans ton projet, le host se connecte directement à la microVM :

```bash
ssh -i ubuntu-24.04.id_rsa root@172.16.0.2
```

Lecture :

- `-i ubuntu-24.04.id_rsa` : clé privée à utiliser
- `root` : utilisateur dans la microVM
- `172.16.0.2` : adresse IP de la microVM

Pourquoi cette connexion fonctionne sans NAT :

- le host et la microVM sont directement voisins sur le lien `tap0 <-> NIC`
- ils sont sur le même sous-réseau `/30`

Exemple concret :

- le host envoie un paquet TCP vers `172.16.0.2:22`
- ce paquet sort par `tap0`
- la NIC de la microVM le reçoit
- le serveur SSH dans la VM répond

Ici, contrairement à un accès Internet :

- il n'y a pas de translation d'adresse
- il n'y a pas de passage par l'interface externe du host

## Table de routage

Une table de routage est la liste des règles qui disent à une machine où envoyer les paquets selon leur destination.

Dans le guest, on a au minimum deux idées :

- le réseau local `172.16.0.0/30` est directement accessible via `eth0`
- tout le reste passe par la route par défaut vers `172.16.0.1`

Exemple mental :

- destination `172.16.0.1` : direct
- destination `172.16.0.2` : local
- destination `1.1.1.1` : passerelle `172.16.0.1`

Cela explique pourquoi la configuration de la route par défaut est indispensable pour l'accès Internet, mais pas pour une simple communication locale avec le host.

## DNS

Le DNS sert à traduire un nom comme `example.com` en adresse IP.

Dans ton script :

```bash
ssh -i $KEY_NAME root@172.16.0.2  "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
```

Effet :

- dans la microVM, `/etc/resolv.conf` est remplacé
- le serveur DNS configuré devient `8.8.8.8`

Pourquoi c'est utile :

- sans DNS, la VM pourrait peut-être faire `ping 8.8.8.8`
- mais pas forcément `ping google.com`

Exemple pédagogique :

- `ping 8.8.8.8` teste surtout la connectivité IP
- `ping google.com` teste aussi la résolution DNS

## Résumé guidé du trajet d'un paquet

Prenons l'exemple de `ping 8.8.8.8` depuis la microVM.

1. la microVM crée un paquet IP de source `172.16.0.2` vers `8.8.8.8`
2. comme `8.8.8.8` n'est pas dans `172.16.0.0/30`, elle utilise la passerelle `172.16.0.1`
3. le paquet sort par sa NIC virtuelle `eth0`
4. Firecracker le transmet sur `tap0` côté host
5. le host reçoit le paquet sur `tap0`
6. grâce à `ip_forward=1`, le host accepte de le router
7. grâce à `iptables` et `MASQUERADE`, le host remplace la source `172.16.0.2` par sa propre IP externe
8. le paquet part vers Internet
9. la réponse revient au host
10. le host annule la translation NAT
11. il renvoie la réponse vers `172.16.0.2` via `tap0`
12. la microVM reçoit la réponse sur `eth0`

Le cas du `ssh root@172.16.0.2` depuis le host est plus simple :

1. le host envoie directement au voisin `172.16.0.2`
2. le trafic passe de `tap0` à la NIC virtuelle de la microVM
3. le serveur SSH du guest répond
4. aucun NAT n'est nécessaire

## Résumé ultra-court

- `host` : la machine Linux réelle
- `guest` : la microVM Firecracker
- `NIC` : la carte réseau virtuelle vue par la microVM
- `tap0` : l'interface virtuelle côté host reliée à cette NIC
- `172.16.0.1` : IP du host sur ce mini-réseau
- `172.16.0.2` : IP du guest sur ce mini-réseau
- `/30` : sous-réseau minimal pour relier deux extrémités
- `gateway` : le host pour la microVM
- `ip_forward` : autorise le host à router
- `iptables` + `MASQUERADE` : permettent au guest de sortir sur Internet
