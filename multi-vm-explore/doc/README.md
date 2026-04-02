# Documentation Multi-VM Explore

Ce répertoire regroupe la documentation de compréhension et de reprise du flux multi-VM Firecracker présent dans ce repository.

## Documents disponibles

### Explication des scripts principaux

- [scripts-multi-vm-explication-ligne-par-ligne.md](/home/olivier/dev/firecracker/multi-vm-explore/doc/scripts-multi-vm-explication-ligne-par-ligne.md)

Contient une explication détaillée, ligne par ligne, de :

- `/home/olivier/dev/firecracker/script/get-kernel.sh`
- `/home/olivier/dev/firecracker/multi-vm-explore/run-firecracker.sh`
- `/home/olivier/dev/firecracker/multi-vm-explore/call-firecracker.sh`

### Explication de l'overlay rootfs

- [rootfs-overlay-explication-ligne-par-ligne.md](/home/olivier/dev/firecracker/multi-vm-explore/doc/rootfs-overlay-explication-ligne-par-ligne.md)

Contient une explication détaillée, ligne par ligne, de :

- `/home/olivier/dev/firecracker/multi-vm-explore/apply-rootfs-overlay.sh`
- `/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/usr/local/bin/fcnet-setup.sh`
- `/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/etc/resolv.conf`
- `/home/olivier/dev/firecracker/multi-vm-explore/rootfs-overlay/app/.keep`

## Notes de session utiles

- [SESSION-2026-03-30-firecracker-multivm.md](/home/olivier/dev/firecracker/SESSION-2026-03-30-firecracker-multivm.md)
- [SESSION-2026-04-01-firecracker-multivm.md](/home/olivier/dev/firecracker/SESSION-2026-04-01-firecracker-multivm.md)

## Ordre de lecture recommandé

Pour comprendre le flux multi-VM dans l'ordre logique :

1. lire [scripts-multi-vm-explication-ligne-par-ligne.md](/home/olivier/dev/firecracker/multi-vm-explore/doc/scripts-multi-vm-explication-ligne-par-ligne.md)
2. lire [rootfs-overlay-explication-ligne-par-ligne.md](/home/olivier/dev/firecracker/multi-vm-explore/doc/rootfs-overlay-explication-ligne-par-ligne.md)
3. relire [SESSION-2026-04-01-firecracker-multivm.md](/home/olivier/dev/firecracker/SESSION-2026-04-01-firecracker-multivm.md) pour reprendre l'état courant

## Résumé rapide du flux

Le flux multi-VM se résume ainsi :

1. `script/get-kernel.sh` reconstruit le rootfs et prépare les artefacts communs
2. `multi-vm-explore/run-firecracker.sh <vm-id>` prépare l'état local d'une VM et lance Firecracker
3. `multi-vm-explore/call-firecracker.sh <vm-id>` configure la VM via l'API et déclenche le boot
4. dans le guest, `fcnet-setup.sh` configure le réseau et monte `/app`
