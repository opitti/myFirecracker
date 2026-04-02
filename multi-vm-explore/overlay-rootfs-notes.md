# Overlay Rootfs Multi-VM

## Objet

Ce document explique :

- ce qui a été ajouté pour débloquer le réseau multi-VM
- comment fonctionne l'overlay guest
- quelles actions il reste à exécuter

## Problème de départ

Le host multi-VM était déjà préparé pour un réseau partagé `172.16.0.0/28` :

- bridge `fcbr0`
- une interface TAP par VM
- une IP invitée réservée par VM
- une MAC dérivée de cette IP
- NAT sortant sur l'hôte

Le blocage venait de l'image invitée :

- `fcnet-setup.sh` configurait encore l'interface réseau en `/30`
- la route par défaut était injectée après boot via SSH dans le script mono-VM
- `/etc/resolv.conf` était aussi réécrit après boot via SSH
- le disque `appfs` n'était pas monté automatiquement dans l'invité

Ce modèle ne convient plus en multi-VM avec un rootfs partagé en lecture seule.

## Ce qui a été ajouté

Un overlay versionné a été créé dans :

- [rootfs-overlay/usr/local/bin/fcnet-setup.sh](/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh)
- [rootfs-overlay/etc/resolv.conf](/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/etc/resolv.conf)
- [rootfs-overlay/app/.keep](/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/app/.keep)

Un script d'application de l'overlay a été ajouté dans :

- [apply-rootfs-overlay.sh](/home/olivier/dev/firecracker/multi-vm-explore/apply-rootfs-overlay.sh)

Le flux de reconstruction du rootfs a été branché sur cet overlay dans :

- [script/get-kernel.sh](/home/olivier/dev/firecracker/script/get-kernel.sh#L22)

## Fonctionnement de l'overlay

L'overlay n'édite pas directement le `squashfs-root` existant dans le repo.

À la place :

1. `get-kernel.sh` extrait une image Ubuntu upstream avec `unsquashfs`
2. le contenu extrait est placé dans `squashfs-root`
3. `apply-rootfs-overlay.sh squashfs-root` copie les fichiers de l'overlay dans cette arborescence
4. `mkfs.ext4 -d squashfs-root ...` reconstruit le rootfs final `ubuntu-24.04.ext4`

Ce mécanisme évite de dépendre des permissions du `squashfs-root` déjà présent localement.

## Détail des fichiers overlay

### `fcnet-setup.sh`

Le script overlay :

- garde le calcul de l'IP à partir de la MAC Firecracker
- applique le masque `/28` au lieu de `/30`
- configure la route par défaut vers `172.16.0.1`
- monte automatiquement `/dev/vdb` sur `/app` si le disque est présent
- formate `/dev/vdb` en ext4 si nécessaire

Effet recherché :

- chaque VM reçoit sa propre IP dans le même sous-réseau partagé
- la sortie réseau ne dépend plus d'une injection manuelle post-boot
- le disque applicatif attaché à la VM devient utilisable automatiquement

### `resolv.conf`

L'overlay fournit un `resolv.conf` statique avec :

```text
nameserver 8.8.8.8
```

But :

- éviter d'écrire dans `/etc/resolv.conf` après boot
- rendre le DNS disponible même avec un rootfs invité monté en lecture seule

### `/app/.keep`

Le fichier `.keep` force la présence du répertoire `/app` dans l'image reconstruite.

But :

- permettre au script guest de monter `appfs` sur `/app`
- éviter de dépendre d'une création tardive dans un rootfs en lecture seule

## Fonctionnement de `apply-rootfs-overlay.sh`

Le script :

- vérifie qu'un argument `rootfs-dir` est fourni
- vérifie que ce répertoire existe
- crée si besoin :
  - `usr/local/bin`
  - `etc`
  - `app`
- copie ensuite les fichiers de l'overlay dans l'arborescence rootfs cible

Commande type :

```bash
./multi-vm-explore/apply-rootfs-overlay.sh squashfs-root
```

## Intégration dans `get-kernel.sh`

La prise en compte de l'overlay se fait ici :

```bash
./multi-vm-explore/apply-rootfs-overlay.sh squashfs-root
```

Cette ligne est exécutée après :

- `unsquashfs ...`
- la copie de la clé SSH dans `squashfs-root/root/.ssh/authorized_keys`

et avant :

- `sudo chown -R root:root squashfs-root`
- `sudo mkfs.ext4 -d squashfs-root -F ubuntu-...ext4`

## Actions à faire

1. Reconstruire le rootfs avec [script/get-kernel.sh](/home/olivier/dev/firecracker/script/get-kernel.sh).
2. Vérifier que le nouveau `ubuntu-24.04.ext4` est bien celui utilisé par les scripts multi-VM.
3. Lancer une première VM avec [multi-vm-explore/run-firecracker.sh](/home/olivier/dev/firecracker/multi-vm-explore/run-firecracker.sh) puis [multi-vm-explore/call-firecracker.sh](/home/olivier/dev/firecracker/multi-vm-explore/call-firecracker.sh).
4. Vérifier dans la VM que l'interface a bien une IP en `/28`.
5. Vérifier que la route par défaut pointe vers `172.16.0.1`.
6. Vérifier que la résolution DNS fonctionne.
7. Vérifier que `/app` est bien monté depuis `/dev/vdb`.
8. Lancer une deuxième VM en parallèle et vérifier que les deux VMs coexistent sur `fcbr0`.
9. Vérifier que chaque VM conserve son propre disque `app-data.ext4`.
10. Ajouter ensuite, si utile, des scripts `list`, `stop` et `cleanup`.

## Point d'attention

Le host-side multi-VM est prêt, mais le test réel dépend encore :

- d'une reconstruction effective du rootfs
- de l'exécution des commandes `sudo` nécessaires
- des dépendances système présentes localement (`unsquashfs`, `mkfs.ext4`, `curl`, `jq`, `iptables`, etc.)
