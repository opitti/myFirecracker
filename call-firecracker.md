# Documentation de `call-firecracker.sh`

Ce document décrit précisément le comportement du script [`call-firecracker.sh`](/home/olivier/dev/firecracker/call-firecracker.sh).

## Rôle du script

`call-firecracker.sh` ne lance pas lui-même le processus Firecracker. Il configure une microVM déjà exposée via l'API Unix socket `/tmp/firecracker.socket`, démarre cette microVM, prépare son accès réseau, puis ouvre une session SSH dans l'invité.

Dans ce dossier, le lancement du processus Firecracker est géré séparément par [`run-firecracker.sh`](/home/olivier/dev/firecracker/run-firecracker.sh), qui exécute :

```bash
sudo ./firecracker --api-sock "/tmp/firecracker.socket" --enable-pci
```

Autrement dit, `call-firecracker.sh` suppose que Firecracker tourne déjà et écoute sur le socket attendu.

## Préconditions implicites

Le script suppose la présence des éléments suivants dans le répertoire courant :

- un noyau Linux dont le nom commence par `vmlinux`
- un root filesystem au format `*.ext4`
- une clé privée SSH dont le nom se termine par `*.id_rsa`
- le binaire `curl`
- `ip`, `iptables`, `jq`, `ssh` et `sudo`
- un démon Firecracker déjà démarré et joignable sur `/tmp/firecracker.socket`

Le script suppose aussi que l'image invitée :

- accepte une connexion SSH en `root`
- est configurée pour utiliser l'adresse IP dérivée de l'adresse MAC `06:00:AC:10:00:02`
- expose son interface réseau sous le nom `eth0`

## Résumé du flux d'exécution

Le script exécute les étapes suivantes :

1. recrée l'interface TAP `tap0` côté hôte
2. attribue à cette interface l'adresse `172.16.0.1/30`
3. active le forwarding IPv4 sur l'hôte
4. active un NAT de sortie avec `iptables`
5. configure Firecracker via son API REST sur socket Unix
6. choisit automatiquement le dernier fichier `vmlinux*` comme noyau
7. choisit automatiquement le dernier fichier `*.ext4` comme disque rootfs
8. configure l'interface réseau de la microVM avec une MAC fixe
9. démarre la microVM
10. choisit automatiquement la dernière clé `*.id_rsa`
11. pousse la route par défaut et le DNS dans l'invité via SSH
12. ouvre une session SSH interactive vers la microVM

## Détail précis par section

## 1. Paramètres réseau initiaux

Les variables suivantes sont définies :

```bash
TAP_DEV="tap0"
TAP_IP="172.16.0.1"
MASK_SHORT="/30"
```

Effet :

- l'interface TAP côté hôte s'appelle `tap0`
- l'hôte prend l'adresse `172.16.0.1/30`
- avec un `/30`, le réseau ne contient que deux adresses utilisables :
  - `172.16.0.1` pour l'hôte
  - `172.16.0.2` pour la microVM

## 2. Recréation de l'interface TAP

Le script exécute :

```bash
sudo ip link del "$TAP_DEV" 2> /dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap
sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"
sudo ip link set dev "$TAP_DEV" up
```

Effet exact :

- toute ancienne interface `tap0` est supprimée si elle existe déjà
- une nouvelle interface TAP `tap0` est créée
- l'adresse `172.16.0.1/30` est assignée à cette interface
- l'interface est montée

Conséquence :

- le script n'est pas idempotent au sens strict, mais il tente de repartir d'un état propre pour `tap0`
- il modifie directement la configuration réseau de l'hôte

## 3. Activation du forwarding et du NAT

Le script exécute :

```bash
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sudo iptables -P FORWARD ACCEPT
HOST_IFACE=$(ip -j route list default |jq -r '.[0].dev')
sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -j MASQUERADE || true
sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -j MASQUERADE
```

Effet exact :

- active le forwarding IPv4 global sur l'hôte
- définit la policy par défaut de la chaîne `FORWARD` à `ACCEPT`
- détecte l'interface de sortie par défaut de l'hôte via la table de routage
- supprime une ancienne règle NAT identique si elle existe
- ajoute une règle `MASQUERADE` pour que le trafic sortant de la microVM soit NATé vers l'extérieur

Points importants :

- la commande `iptables -P FORWARD ACCEPT` change la politique globale de forwarding de la machine hôte
- `HOST_IFACE` dépend de `jq` et du résultat de `ip -j route list default`
- si l'hôte a plusieurs routes par défaut ou une topologie réseau particulière, l'interface détectée peut être mauvaise
- le script ne restaure pas l'état initial d'`iptables` à la fin

## 4. Utilisation du socket API Firecracker

Les variables suivantes sont définies :

```bash
API_SOCKET="/tmp/firecracker.socket"
LOGFILE="./firecracker.log"
```

Effet :

- toutes les requêtes de configuration sont envoyées à l'API Firecracker via le socket Unix `/tmp/firecracker.socket`
- les logs Firecracker sont écrits dans `./firecracker.log`

Si le processus Firecracker n'écoute pas déjà sur ce socket, toutes les requêtes `curl --unix-socket` échoueront.

## 5. Configuration du logger Firecracker

Le script envoie :

```json
{
  "log_path": "./firecracker.log",
  "level": "Debug",
  "show_level": true,
  "show_log_origin": true
}
```

vers l'endpoint `PUT /logger`.

Effet exact :

- active les logs Firecracker dans le fichier `firecracker.log`
- règle le niveau de log à `Debug`
- demande l'affichage du niveau et de l'origine des messages

## 6. Sélection du noyau et des arguments de boot

Le script choisit :

```bash
KERNEL="./$(ls vmlinux* | tail -1)"
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1"
ARCH=$(uname -m)
```

Puis, sur `aarch64` uniquement :

```bash
KERNEL_BOOT_ARGS="keep_bootcon ${KERNEL_BOOT_ARGS}"
```

Effet exact :

- prend le dernier nom renvoyé par `ls vmlinux* | tail -1`
- définit les arguments de boot du noyau
- ajoute `keep_bootcon` sur ARM64 pour conserver la console de boot

Limites :

- le choix du noyau dépend de l'ordre de sortie de `ls`, pas d'une sélection explicite ou robuste
- si plusieurs fichiers `vmlinux*` existent, le script prend simplement le dernier

## 7. Configuration de la source de boot

Le script envoie :

```json
{
  "kernel_image_path": "<chemin du noyau>",
  "boot_args": "<arguments du noyau>"
}
```

vers `PUT /boot-source`.

Effet :

- indique à Firecracker quel noyau charger
- indique la ligne de commande du noyau à utiliser

## 8. Sélection et configuration du root filesystem

Le script choisit :

```bash
ROOTFS="./$(ls *.ext4 | tail -1)"
```

Puis il envoie :

```json
{
  "drive_id": "rootfs",
  "path_on_host": "<chemin du rootfs>",
  "is_root_device": true,
  "is_read_only": false
}
```

vers `PUT /drives/rootfs`.

Effet exact :

- prend le dernier fichier `*.ext4` du dossier courant
- l'attache comme disque racine de la microVM
- le monte en lecture/écriture

Point important :

- `is_read_only: false` autorise la modification du root filesystem par l'invité

## 9. Configuration réseau de la microVM

Le script fixe :

```bash
FC_MAC="06:00:AC:10:00:02"
```

Puis il envoie :

```json
{
  "iface_id": "net1",
  "guest_mac": "06:00:AC:10:00:02",
  "host_dev_name": "tap0"
}
```

vers `PUT /network-interfaces/net1`.

Effet exact :

- relie l'interface réseau virtuelle de la microVM à l'interface TAP `tap0` côté hôte
- impose une adresse MAC fixe à la carte réseau invitée

Le commentaire du script précise que l'adresse IP de l'invité est dérivée de cette MAC par une configuration préalable dans l'image invitée. Le script part donc du principe que :

- la microVM utilisera `172.16.0.2`
- cette IP est cohérente avec `TAP_IP=172.16.0.1/30`

## 10. Temporisation avant démarrage

Le script attend :

```bash
sleep 0.015s
```

Raison :

- les requêtes API Firecracker sont traitées de manière asynchrone
- le script laisse un court délai pour éviter d'envoyer `InstanceStart` avant que la configuration précédente soit prise en compte

## 11. Démarrage de la microVM

Le script envoie :

```json
{
  "action_type": "InstanceStart"
}
```

vers `PUT /actions`.

Effet :

- demande à Firecracker de démarrer effectivement la microVM avec la configuration déjà fournie

## 12. Attente de boot

Le script attend :

```bash
sleep 2s
```

Raison :

- laisse le temps au noyau et à l'espace utilisateur de démarrer avant la première connexion SSH

Limite :

- `2s` est une temporisation fixe
- si la VM démarre plus lentement, les commandes SSH suivantes peuvent échouer

## 13. Sélection de la clé SSH

Le script choisit :

```bash
KEY_NAME=./$(ls *.id_rsa | tail -1)
```

Effet :

- sélectionne le dernier fichier correspondant à `*.id_rsa`

Limite :

- si plusieurs clés sont présentes, le choix peut ne pas être celui attendu

## 14. Configuration réseau dans l'invité via SSH

Le script exécute successivement :

```bash
ssh -i $KEY_NAME root@172.16.0.2 "ip route add default via 172.16.0.1 dev eth0"
ssh -i $KEY_NAME root@172.16.0.2 "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"
```

Effet exact dans la microVM :

- ajoute une route par défaut via l'hôte `172.16.0.1` sur `eth0`
- remplace `/etc/resolv.conf` par un fichier contenant uniquement `nameserver 8.8.8.8`

Conséquences :

- l'accès Internet sortant de l'invité passe par le NAT configuré côté hôte
- la résolution DNS de l'invité repose explicitement sur le serveur Google `8.8.8.8`
- toute configuration DNS précédente dans l'invité est écrasée

## 15. Ouverture d'une session interactive

Enfin, le script exécute :

```bash
ssh -i $KEY_NAME root@172.16.0.2
```

Effet :

- ouvre une session SSH interactive vers la microVM

Les derniers commentaires indiquent :

- l'utilisateur attendu est `root`
- le mot de passe serait `root`
- `reboot` peut être utilisé pour quitter

En pratique, le script utilise une authentification par clé privée avec `ssh -i`, pas une authentification interactive par mot de passe.

## Effets de bord sur l'hôte

Le script a plusieurs effets persistants ou semi-persistants :

- création ou recréation de `tap0`
- activation du forwarding IPv4 sur l'hôte
- changement global de la policy `iptables` de `FORWARD` à `ACCEPT`
- ajout d'une règle NAT `MASQUERADE`
- écriture de logs dans `firecracker.log`

Il n'y a pas de nettoyage final dans ce script.

## Points fragiles ou implicites

Voici les hypothèses les plus importantes du script :

- Firecracker doit déjà être lancé avant l'exécution du script
- `jq` doit être installé
- l'image invitée doit accepter `root@172.16.0.2`
- l'invité doit disposer de `ip` et d'un `eth0`
- la MAC `06:00:AC:10:00:02` doit correspondre à la logique réseau déjà intégrée au rootfs
- les commandes `ls ... | tail -1` doivent sélectionner les bons fichiers
- les temporisations `0.015s` et `2s` doivent être suffisantes

## Enchaînement attendu avec les scripts présents

Dans ce dossier, l'ordre d'usage implicite est le suivant :

1. exécuter [`run-firecracker.sh`](/home/olivier/dev/firecracker/run-firecracker.sh) pour démarrer le processus Firecracker et créer `/tmp/firecracker.socket`
2. exécuter [`call-firecracker.sh`](/home/olivier/dev/firecracker/call-firecracker.sh) pour configurer, démarrer et rejoindre la microVM

## Fichiers repérés dans ce dossier utilisés par le script

Dans l'état actuel du répertoire `/home/olivier/dev/firecracker`, les sélections automatiques du script correspondent à :

- noyau : `./vmlinux-6.1.155`
- rootfs : `./ubuntu-24.04.ext4`
- clé SSH : `./ubuntu-24.04.id_rsa`
- fichier de log : `./firecracker.log`

## Conclusion

`call-firecracker.sh` est un script d'orchestration locale pour une microVM Firecracker déjà lancée côté hôte. Il prépare le réseau hôte, configure la VM via l'API Firecracker, démarre l'instance, injecte la route par défaut et le DNS dans l'invité, puis ouvre une session SSH sur `172.16.0.2`.
