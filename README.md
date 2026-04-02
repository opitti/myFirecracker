# Firecracker Multi-VM

Workspace personnel pour orchestrer plusieurs microVMs [Firecracker](https://firecracker-microvm.github.io/) sur un hôte Linux. Ce dépôt ne compile pas Firecracker — il télécharge les binaires pré-compilés et scripte la configuration réseau + stockage pour faire tourner plusieurs VMs isolées en parallèle.

## Prérequis

- Linux x86_64 ou aarch64
- `sudo`, `curl`, `wget`, `jq`, `unsquashfs`, `mkfs.ext4`, `iptables`
- Accès réseau pour télécharger les artefacts depuis GitHub et S3

## Installation

### 1. Télécharger le binaire Firecracker

```bash
bash get-firecracker.sh
```

Télécharge la dernière version de Firecracker depuis GitHub et place le binaire à la racine du dépôt.

### 2. Préparer le kernel et le rootfs

```bash
bash script/get-kernel.sh
```

Ce script :
- Télécharge le kernel Linux (`vmlinux-6.1.x`) depuis le CI Firecracker
- Télécharge l'image Ubuntu 24.04 (squashfs)
- Génère une paire de clés SSH et l'injecte dans le rootfs
- Applique l'overlay réseau (via `multi-vm-explore/apply-rootfs-overlay.sh`)
- Convertit le tout en image ext4 (`ubuntu-24.04.ext4`)

Artefacts produits :

| Fichier | Rôle |
|---------|------|
| `vmlinux-6.1.x` | Kernel Linux |
| `ubuntu-24.04.ext4` | Rootfs partagé (lecture seule) |
| `ubuntu-24.04.id_rsa` | Clé SSH privée pour se connecter aux VMs |

## Lancer des VMs

Chaque VM nécessite deux terminaux (ou processus en arrière-plan).

### Terminal A — démarrer le daemon Firecracker

```bash
./multi-vm-explore/run-firecracker.sh vm1
```

Alloue une IP unique dans `172.16.0.2–14/28`, crée le répertoire d'état et le disque applicatif, puis lance le daemon Firecracker sur un socket Unix dédié.

### Terminal B — configurer et démarrer la VM via l'API

```bash
./multi-vm-explore/call-firecracker.sh vm1
```

Crée le bridge `fcbr0` et l'interface TAP, configure iptables pour l'accès internet, puis appelle l'API HTTP Firecracker pour attacher le kernel, le rootfs, le disque `/app` et le réseau, puis démarre la VM.

Répéter avec `vm2`, `vm3`, etc. pour des VMs supplémentaires (jusqu'à 13 simultanées).

### Se connecter en SSH

```bash
ssh -i ubuntu-24.04.id_rsa root@172.16.0.2   # vm1
ssh -i ubuntu-24.04.id_rsa root@172.16.0.3   # vm2
```

## Architecture

### Topologie réseau

```
Hôte (172.16.0.1)
└── fcbr0 (bridge, /28)
    ├── fctap2 ──── VM vm1  172.16.0.2
    ├── fctap3 ──── VM vm2  172.16.0.3
    └── ...
[iptables MASQUERADE] → eth0 hôte → internet
```

### Stockage

- **Rootfs partagé** — `ubuntu-24.04.ext4` monté en lecture seule par toutes les VMs
- **Disque applicatif par VM** — `multi-vm-explore/state/vms/<vm-id>/app-data.ext4`, monté à `/app` dans le guest

### Initialisation réseau dans le guest

Au démarrage, le service systemd `fcnet-setup` exécute `fcnet-setup.sh` qui :
- Dérive l'IP guest à partir de l'adresse MAC (octets → `172.16.0.XX/28`)
- Configure la route par défaut via `172.16.0.1`
- Monte `/dev/vdb` sur `/app` si le disque est présent

## Structure du dépôt

```
.
├── get-firecracker.sh                      # Télécharge le binaire Firecracker
├── script/
│   └── get-kernel.sh                       # Télécharge kernel + rootfs + clés SSH
├── multi-vm-explore/
│   ├── run-firecracker.sh                  # Lance le daemon Firecracker (par VM)
│   ├── call-firecracker.sh                 # Configure et démarre la VM via l'API
│   ├── apply-rootfs-overlay.sh             # Injecte l'overlay dans le rootfs
│   ├── rootfs-overlay/                     # Fichiers injectés dans le guest
│   │   └── usr/local/bin/fcnet-setup.sh   # Init réseau + montage /app au boot
│   ├── state/vms/                          # État par VM (socket, disque, métadonnées)
│   └── doc/                                # Documentation détaillée des scripts
├── firecracker-network-diagrams.md         # Schémas réseau
└── firecracker-network-glossary.md         # Glossaire réseau
```

## Documentation

- `multi-vm-explore/doc/` — explications ligne par ligne des scripts et index de lecture
- `firecracker-network-diagrams.md` — diagrammes de la topologie réseau
- `firecracker-network-glossary.md` — glossaire des termes réseau (TAP, bridge, MASQUERADE…)
- `SESSION-*.md` — journal de session avec décisions et corrections de bugs
