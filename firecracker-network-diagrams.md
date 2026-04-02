# Schémas réseau Firecracker

Ce document regroupe les schémas et explications de la topologie réseau utilisée par [`call-firecracker.sh`](/home/olivier/dev/firecracker/call-firecracker.sh).

## 1. Vue d'ensemble

```text
                    HOST LINUX
    +--------------------------------------------------+
    |                                                  |
    |  Interface réseau physique / Wi‑Fi               |
    |  ex: eth0 / enp0s... / wlp...                    |
    |                  |                               |
    |                  | trafic sortant                |
    |           +------+--------------------------+    |
    |           | NAT / iptables / ip_forward     |    |
    |           +------+--------------------------+    |
    |                  |                               |
    |               tap0                               |
    |        IP: 172.16.0.1/30                         |
    +------------------|-------------------------------+
                       |
                       | lien virtuel Ethernet
                       |
    +------------------|-------------------------------+
    |          microVM Firecracker                     |
    |                                                  |
    |   NIC virtuelle de la VM                         |
    |   MAC: 06:00:AC:10:00:02                         |
    |   nom dans la VM: eth0                           |
    |   IP: 172.16.0.2/30                              |
    |                                                  |
    |   route par défaut -> 172.16.0.1                 |
    |   DNS -> 8.8.8.8                                 |
    +--------------------------------------------------+
```

Résumé :

- le host est la machine Linux physique ou principale
- `tap0` est l'interface TAP côté host
- la microVM voit une carte réseau virtuelle, sa NIC, typiquement nommée `eth0`
- Firecracker relie la NIC virtuelle de la microVM à `tap0`
- le host utilise `iptables` et `ip_forward` pour laisser sortir la VM vers Internet

## 2. Flux d'un `ping 8.8.8.8` depuis la microVM

```text
Dans la microVM
ping 8.8.8.8
    |
    v
+---------------------------+
| eth0                      |
| IP source: 172.16.0.2     |
| GW: 172.16.0.1            |
+-------------+-------------+
              |
              | paquet ICMP vers 8.8.8.8
              v
================ lien virtuel =================
              |
              v
+---------------------------+
| tap0 sur le host          |
| IP: 172.16.0.1            |
+-------------+-------------+
              |
              | forwarding IPv4
              v
+---------------------------+
| iptables / NAT            |
| source 172.16.0.2         |
| devient IP du host        |
+-------------+-------------+
              |
              v
+---------------------------+
| Interface réseau du host  |
| ex: eth0 / wlan0          |
+-------------+-------------+
              |
              v
           Internet
              |
              v
            8.8.8.8

Chemin retour

8.8.8.8
  |
  v
Internet
  |
  v
Interface réseau du host
  |
  v
iptables / NAT
retour vers 172.16.0.2
  |
  v
tap0
  |
  v
eth0 dans la microVM
  |
  v
réponse reçue par `ping`
```

À retenir :

- la VM émet avec l'adresse source `172.16.0.2`
- le host NATe ce trafic avant de l'envoyer vers Internet
- Internet ne voit donc pas `172.16.0.2`, mais l'adresse IP du host
- au retour, le host réassocie les réponses à la VM et les renvoie vers `tap0`

## 3. Flux d'une connexion SSH du host vers la microVM

```text
Connexion SSH depuis le host vers la microVM

Utilisateur sur le host
ssh -i ubuntu-24.04.id_rsa root@172.16.0.2
    |
    v
+-----------------------------+
| Host Linux                  |
| processus ssh client        |
+--------------+--------------+
               |
               | destination: 172.16.0.2:22
               v
+-----------------------------+
| tap0                        |
| IP host: 172.16.0.1/30      |
+--------------+--------------+
               |
               | lien virtuel Ethernet
               v
+-----------------------------+
| NIC virtuelle de la microVM |
| nom dans la VM: eth0        |
| IP guest: 172.16.0.2/30     |
+--------------+--------------+
               |
               | port 22
               v
+-----------------------------+
| serveur SSH dans la microVM |
| utilisateur: root           |
+-----------------------------+
```

À retenir :

- ici, le trafic reste local entre le host et la microVM
- il ne traverse pas Internet
- il n'a pas besoin de NAT
- `tap0` joue simplement le rôle de lien réseau local entre le host et la VM

## 4. Explication détaillée des commandes TAP

Le script utilise les variables suivantes :

```bash
TAP_DEV="tap0"
TAP_IP="172.16.0.1"
MASK_SHORT="/30"
```

Ce que cela signifie :

- `TAP_DEV="tap0"` : le nom de l'interface TAP créée sur le host sera `tap0`
- `TAP_IP="172.16.0.1"` : l'adresse IP du host sur ce mini-réseau sera `172.16.0.1`
- `MASK_SHORT="/30"` : le réseau a un masque `/30`, donc seulement 4 adresses au total

Avec `172.16.0.1/30`, le sous-réseau est :

- réseau : `172.16.0.0`
- host Linux : `172.16.0.1`
- microVM : `172.16.0.2`
- broadcast : `172.16.0.3`

Un `/30` est un choix courant quand on veut un lien point-à-point très petit entre deux machines seulement :

- une extrémité côté host
- une extrémité côté microVM

## 5. Détail commande par commande, mot par mot

### `sudo ip link del "$TAP_DEV" 2> /dev/null || true`

Avec `TAP_DEV="tap0"`, cela devient :

```bash
sudo ip link del "tap0" 2> /dev/null || true
```

Décomposition complète :

- `sudo`
  - exécute la commande avec les privilèges administrateur
  - ici c'est nécessaire parce que créer, supprimer ou modifier une interface réseau est une opération système sensible
- `ip`
  - c'est l'outil standard Linux pour gérer le réseau
  - il sert à manipuler :
    - les interfaces réseau
    - les adresses IP
    - les routes
    - les interfaces virtuelles
  - on peut le voir comme le "couteau suisse réseau" de Linux
- `link`
  - sous-commande de `ip`
  - elle agit sur l'interface réseau elle-même
  - ici, on ne parle pas encore d'adresse IP ni de route, mais du fait que l'interface existe ou non
- `del`
  - signifie `delete`
  - demande à Linux de supprimer l'interface nommée ensuite
- `"tap0"`
  - c'est le nom de l'interface à supprimer
  - les guillemets viennent du shell et protègent la valeur
- `2>`
  - ce n'est pas une partie de `ip`
  - c'est une redirection du shell
  - `2` désigne la sortie d'erreur standard, appelée `stderr`
- `/dev/null`
  - fichier spécial Linux qui jette tout ce qu'on lui envoie
  - c'est un "trou noir"
- `||`
  - opérateur logique du shell
  - signifie : "si la commande de gauche échoue, exécute celle de droite"
- `true`
  - commande qui réussit toujours
  - elle permet de dire au shell : "même si la suppression échoue, continue"

Pourquoi `2> /dev/null` :

- les messages d'erreur sont jetés, par exemple si `tap0` n'existe pas

Pourquoi `|| true` :

- même si la suppression échoue, le script continue
- cela permet de repartir d'un état propre sans casser l'exécution au premier lancement

En pratique :

- si `tap0` existe déjà, elle est supprimée
- si `tap0` n'existe pas, ce n'est pas considéré comme bloquant

Lecture en français simple :

- "essaie de supprimer `tap0`"
- "si ça échoue, n'affiche pas l'erreur"
- "et considère quand même que ce n'est pas grave"

Exemple concret :

- premier lancement : `tap0` n'existe probablement pas, donc la suppression échoue, mais le script continue
- deuxième lancement : `tap0` peut déjà exister, donc elle est supprimée pour repartir d'un état propre

### `sudo ip tuntap add dev "$TAP_DEV" mode tap`

Avec `TAP_DEV="tap0"`, cela devient :

```bash
sudo ip tuntap add dev "tap0" mode tap
```

Décomposition complète :

- `sudo`
  - exécute la commande en administrateur
- `ip`
  - outil Linux de gestion du réseau
- `tuntap`
  - sous-commande de `ip` pour gérer les interfaces `TUN` et `TAP`
  - ce sont des interfaces réseau virtuelles
  - `TUN` transporte des paquets IP
  - `TAP` transporte des trames Ethernet complètes
- `add`
  - signifie "ajoute" ou "crée"
  - ici, on crée une nouvelle interface
- `dev`
  - abréviation de `device`
  - indique le nom de l'interface concernée
  - on peut le lire comme : "le périphérique réseau s'appellera..."
- `"tap0"`
  - nom donné à l'interface créée
- `mode`
  - précise le type exact de l'interface TUN/TAP
- `tap`
  - demande une interface de type TAP

Pourquoi `mode tap` :

- une interface TAP transporte des trames Ethernet complètes
- c'est adapté à une VM, car la VM s'attend à voir une vraie carte réseau Ethernet

En pratique :

- `tap0` apparaît côté host comme une interface réseau virtuelle
- Firecracker pourra brancher la NIC virtuelle de la microVM dessus

Ce que veut dire "trames Ethernet complètes" :

- une vraie carte réseau Ethernet échange des trames
- une trame contient notamment :
  - une adresse MAC source
  - une adresse MAC destination
  - un type de protocole
  - une charge utile, souvent un paquet IP
- une interface TAP reproduit ce comportement

Pourquoi c'est utile pour Firecracker :

- la microVM se comporte comme une machine avec une vraie carte réseau
- Firecracker a donc besoin d'une extrémité réseau côté host capable de parler Ethernet
- `tap0` joue ce rôle

Lecture en français simple :

- "crée une interface réseau virtuelle"
- "appelle-la `tap0`"
- "et fais-en une interface TAP"

Exemple concret :

- après cette commande, `tap0` existe sur le host
- mais elle n'a pas encore d'adresse IP
- et elle n'est pas encore forcément activée

Note importante :

- ici `ip tuntap` est bien une sous-commande unique de `ip`
- ce n'est pas :
  - une commande `ip`
  - suivie d'une autre commande `tuntap`
- la structure réelle est :
  - commande principale : `ip`
  - objet ou famille d'objet : `tuntap`
  - action : `add`

### `sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"`

Avec `TAP_IP="172.16.0.1"` et `MASK_SHORT="/30"`, cela devient :

```bash
sudo ip addr add "172.16.0.1/30" dev "tap0"
```

Décomposition complète :

- `sudo`
  - exécute la commande en administrateur
- `ip`
  - outil Linux de gestion du réseau
- `addr`
  - sous-commande de `ip`
  - `addr` est l'abréviation de `address`
  - elle sert à manipuler les adresses IP des interfaces
- `add`
  - signifie "ajoute"
  - ici, on ajoute une adresse IP à une interface
- `"172.16.0.1/30"`
  - c'est l'adresse à affecter
  - elle est formée par concaténation des variables shell :
    - `TAP_IP="172.16.0.1"`
    - `MASK_SHORT="/30"`
- `dev`
  - indique à quelle interface réseau on associe cette adresse
- `"tap0"`
  - nom de l'interface qui recevra l'adresse

Pourquoi cette adresse :

- `172.16.0.1` est l'adresse du host sur ce réseau privé entre host et microVM
- la VM est censée prendre `172.16.0.2`
- le host devient donc la passerelle de la VM

Pourquoi `172.16.0.1` précisément :

- `172.16.0.0/12` appartient aux plages privées RFC1918
- c'est une plage adaptée à un réseau local interne, non routé sur Internet
- `172.16.0.1` est choisi par convention comme première adresse utilisable du sous-réseau
- cela rend naturel le couple :
  - host : `172.16.0.1`
  - guest : `172.16.0.2`

Pourquoi un `/30` :

- il faut seulement deux adresses utilisables
- cela limite l'espace d'adressage au strict nécessaire
- cela exprime clairement qu'il s'agit d'un lien dédié entre deux extrémités

Qu'est-ce qu'une adresse IP dans ce contexte :

- une interface réseau peut recevoir une ou plusieurs adresses IP
- l'adresse IP permet d'identifier cette interface dans un réseau IP
- ici, `tap0` devient joignable à l'adresse `172.16.0.1`

Qu'est-ce que `/30` :

- c'est la longueur du préfixe réseau en notation CIDR
- cela signifie que les 30 premiers bits décrivent le réseau
- il reste 2 bits pour numéroter les adresses dans ce sous-réseau
- 2 bits donnent 4 adresses possibles au total

Pour `172.16.0.0/30`, ces 4 adresses sont :

- `172.16.0.0` : adresse de réseau
- `172.16.0.1` : première adresse utilisable
- `172.16.0.2` : deuxième adresse utilisable
- `172.16.0.3` : adresse de broadcast

Pourquoi on choisit `172.16.0.1` pour le host :

- on veut deux adresses utilisables seulement : une pour le host, une pour la microVM
- il est courant de donner la première adresse utilisable à la passerelle ou au routeur
- ici, le host joue précisément ce rôle de passerelle

Pourquoi `dev` est indispensable :

- une machine Linux peut avoir de nombreuses interfaces :
  - `lo`
  - `eth0`
  - `wlan0`
  - `tap0`
  - d'autres interfaces virtuelles
- il faut donc dire explicitement à Linux sur quelle interface poser l'adresse

Lecture en français simple :

- "ajoute l'adresse `172.16.0.1/30` sur l'interface `tap0`"

Exemple concret :

- avant cette commande, `tap0` existe mais n'a pas encore d'identité IP
- après cette commande, le host possède l'adresse `172.16.0.1` sur ce lien local
- la microVM pourra ensuite considérer `172.16.0.1` comme son voisin direct et sa passerelle

### `sudo ip link set dev "$TAP_DEV" up`

Avec `TAP_DEV="tap0"`, cela devient :

```bash
sudo ip link set dev "tap0" up
```

Décomposition complète :

- `sudo`
  - exécute la commande en administrateur
- `ip`
  - outil Linux de gestion du réseau
- `link`
  - on agit sur l'interface elle-même
- `set`
  - signifie "modifie" ou "règle"
  - ici, on change l'état de l'interface
- `dev`
  - indique quelle interface est visée
- `"tap0"`
  - nom de l'interface concernée
- `up`
  - met l'interface à l'état actif

Pourquoi c'est nécessaire :

- une interface peut exister mais rester désactivée
- tant qu'elle n'est pas `UP`, elle ne sert pas au trafic normal

En pratique :

- après cette commande, `tap0` est prête à transporter du trafic
- Firecracker peut s'en servir comme extrémité host du lien réseau de la microVM

Qu'est-ce que l'état `UP` :

- sous Linux, une interface réseau peut être présente mais inactive
- l'état `UP` signifie qu'on l'active administrativement
- cela ne garantit pas que tout fonctionne, mais cela autorise l'interface à être utilisée normalement

Différence simple :

- interface créée mais `down` : elle existe, mais elle n'est pas prête à servir
- interface `up` : elle peut participer au trafic

Lecture en français simple :

- "active l'interface `tap0`"

Exemple concret :

- si tu oublies cette commande, `tap0` peut exister et avoir une IP, mais le trafic ne fonctionnera pas comme prévu

## 6. Ce qui relève du shell et ce qui relève de la commande `ip`

Il faut distinguer deux couches différentes dans ces lignes.

Première couche : le shell `bash`

- il remplace les variables comme `"$TAP_DEV"`
- il gère les redirections comme `2> /dev/null`
- il gère les opérateurs logiques comme `||`
- il gère les guillemets

Deuxième couche : la commande `ip`

- elle reçoit déjà les valeurs finales après expansion du shell
- elle interprète des mots comme :
  - `link`
  - `addr`
  - `tuntap`
  - `add`
  - `del`
  - `set`
  - `dev`
  - `up`

Exemple :

Dans :

```bash
sudo ip link del "$TAP_DEV" 2> /dev/null || true
```

- le shell transforme d'abord `"$TAP_DEV"` en `"tap0"`
- ensuite il exécute `sudo ip link del "tap0"`
- séparément, il redirige les erreurs vers `/dev/null`
- séparément encore, il applique la logique `|| true`

Autrement dit :

- `2> /dev/null` et `|| true` ne sont pas compris par `ip`
- ce sont des mécanismes du shell autour de la commande `ip`

## 7. Lecture humaine des quatre lignes

Voici la traduction la plus simple possible :

1. `sudo ip link del "$TAP_DEV" 2> /dev/null || true`
   - essaie de supprimer `tap0`, et si elle n'existe pas, ignore l'erreur
2. `sudo ip tuntap add dev "$TAP_DEV" mode tap`
   - crée une interface réseau virtuelle TAP appelée `tap0`
3. `sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "$TAP_DEV"`
   - donne l'adresse `172.16.0.1/30` à `tap0`
4. `sudo ip link set dev "$TAP_DEV" up`
   - active `tap0`

## 8. Résumé final

Les quatre commandes font exactement ceci :

1. suppriment une ancienne interface `tap0` si elle existe
2. recréent une interface TAP neuve appelée `tap0`
3. donnent à cette interface l'adresse `172.16.0.1/30`
4. activent l'interface pour qu'elle puisse transporter le trafic

Le choix de `172.16.0.1` vient du fait que le host joue le rôle de passerelle sur un petit réseau privé point-à-point, et que la microVM utilise l'adresse voisine `172.16.0.2`.
