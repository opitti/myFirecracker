# Session Notes - 2026-03-30

## Objectif

Mettre en place un flux Firecracker permettant :
- de séparer le rootfs Ubuntu du dossier `/app`
- de persister `/app` sur un disque dédié
- d'évoluer vers plusieurs microVMs en parallèle avec une socket, une IP et un disque `/app` par VM

## Contexte établi

- Le rootfs actuel est `ubuntu-24.04.ext4`.
- Le script existant [call-firecracker.sh](/home/olivier/dev/firecracker/call-firecracker.sh) attache ce rootfs en écriture, donc `/app` persiste déjà tant que ce même fichier `.ext4` est réutilisé.
- Une première séparation rootfs/app a été créée dans :
  - `/home/olivier/dev/firecracker/split-rootfs-app/run-firecracker.sh`
  - `/home/olivier/dev/firecracker/split-rootfs-app/call-firecracker.sh`
- Cette version attache :
  - `ubuntu-24.04.ext4` pour l'OS
  - `split-rootfs-app/app-data.ext4` pour `/app`

## Exploration multi-VM

Une base d'orchestration multi-VM a été créée dans :
- `/home/olivier/dev/firecracker/multi-vm-explore/run-firecracker.sh`
- `/home/olivier/dev/firecracker/multi-vm-explore/call-firecracker.sh`

### Ce que fait `multi-vm-explore/run-firecracker.sh <vm-id>`

- crée un dossier d'état dédié par VM sous `multi-vm-explore/state/vms/<vm-id>/`
- crée une socket Firecracker unique par VM
- réserve une IP libre dans `172.16.0.0/28`
- calcule la MAC correspondante
- crée un disque applicatif `app-data.ext4` de 100 Mo par VM
- stocke les métadonnées dans `vm.env`

### Ce que fait `multi-vm-explore/call-firecracker.sh <vm-id>`

- relit `vm.env`
- prépare un bridge partagé `fcbr0`
- crée un TAP dédié à la VM
- attache :
  - le rootfs `ubuntu-24.04.ext4` en lecture seule
  - le disque `app-data.ext4` dédié à la VM
- configure l'instance via la socket de cette VM

## Point bloquant identifié

Le guest configure son IP automatiquement via :
- `/home/olivier/dev/firecracker/squashfs-root/usr/local/bin/fcnet-setup.sh`

Il est lancé par :
- `/home/olivier/dev/firecracker/squashfs-root/etc/systemd/system/fcnet.service`

### Logique actuelle de `fcnet-setup.sh`

- il lit la MAC de l'interface réseau
- il prend les 4 octets après le préfixe `06:00:`
- il convertit ces octets hexadécimaux en IP IPv4
- il assigne cette IP avec un masque `/30`

Exemple :
- `06:00:ac:10:00:02` -> `172.16.0.2/30`

### Conséquence

Le design multi-VM côté host peut réserver plusieurs IPs sur un `/28`, mais le guest reste configuré en `/30`.
Donc le multi-VM partagé sur le même bridge n'est pas encore réellement fonctionnel tant que cette partie n'est pas corrigée dans l'image invitée.

## Avancement ajouté après reprise

Un overlay guest versionné a été ajouté pour débloquer le multi-VM :

- `/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh`
- `/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/etc/resolv.conf`
- `/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/app/.keep`

Cet overlay prépare l'image invitée pour :

- configurer l'IP invitée sur `172.16.0.0/28`
- poser la route par défaut via `172.16.0.1`
- monter automatiquement le second disque block sur `/app`
- fournir un `resolv.conf` statique compatible avec un rootfs partagé en lecture seule

Le script `/home/olivier/dev/firecracker/multi-vm-explore/apply-rootfs-overlay.sh`
permet de copier cet overlay dans une arborescence rootfs, et
`/home/olivier/dev/firecracker/script/get-kernel.sh` appelle maintenant cet overlay
avant de reconstruire `ubuntu-24.04.ext4`.

## Prochaine étape recommandée

Reconstruire ou mettre à jour le rootfs utilisé par Firecracker, puis tester deux microVMs en parallèle.

Ensuite :
- vérifier que chaque VM obtient bien son IP sur `172.16.0.0/28`
- vérifier le montage automatique de `app-data.ext4` sur `/app`
- ajouter éventuellement des scripts `list`, `stop`, `cleanup`

## Décision utilisateur la plus récente

L'utilisateur a demandé à sauvegarder cette conversation pour la reprendre plus tard.
