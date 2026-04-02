#!/usr/bin/env bash

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <vm-id>" >&2
    exit 1
fi

VM_ID="$1"
if [[ ! "${VM_ID}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Invalid vm-id: ${VM_ID}" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VM_DIR="${SCRIPT_DIR}/state/vms/${VM_ID}"
META_FILE="${VM_DIR}/vm.env"

if [ ! -f "${META_FILE}" ]; then
    echo "Unknown vm-id: ${VM_ID}" >&2
    echo "Start it first with ./run-firecracker.sh ${VM_ID}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${META_FILE}"

if [ ! -S "${API_SOCKET}" ]; then
    echo "Firecracker socket not ready: ${API_SOCKET}" >&2
    echo "Start the VM process first with ./run-firecracker.sh ${VM_ID}" >&2
    exit 1
fi

HOST_IFACE="$(ip -j route list default | jq -r '.[0].dev')"
KERNEL="${ROOT_DIR}/$(ls "${ROOT_DIR}"/vmlinux* | tail -1 | xargs basename)"
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1"
ARCH="$(uname -m)"

if [ "${ARCH}" = "aarch64" ]; then
    KERNEL_BOOT_ARGS="keep_bootcon ${KERNEL_BOOT_ARGS}"
fi

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

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"log_path\": \"${LOGFILE}\",
        \"level\": \"Debug\",
        \"show_level\": true,
        \"show_log_origin\": true
    }" \
    "http://localhost/logger"

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"kernel_image_path\": \"${KERNEL}\",
        \"boot_args\": \"${KERNEL_BOOT_ARGS}\"
    }" \
    "http://localhost/boot-source"

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"${ROOTFS}\",
        \"is_root_device\": true,
        \"is_read_only\": true
    }" \
    "http://localhost/drives/rootfs"

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"drive_id\": \"appfs\",
        \"path_on_host\": \"${APPFS}\",
        \"is_root_device\": false,
        \"is_read_only\": false
    }" \
    "http://localhost/drives/appfs"

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"iface_id\": \"net1\",
        \"guest_mac\": \"${GUEST_MAC}\",
        \"host_dev_name\": \"${TAP_DEV}\"
    }" \
    "http://localhost/network-interfaces/net1"

sleep 0.015s

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"action_type\": \"InstanceStart\"
    }" \
    "http://localhost/actions"

cat <<EOF
VM ${VM_ID} configured
  socket: ${API_SOCKET}
  bridge: ${BRIDGE_DEV}
  tap: ${TAP_DEV}
  guest_ip: ${GUEST_IP}
  guest_mac: ${GUEST_MAC}
  app_disk: ${APPFS}

Guest rootfs reminder:
  Rebuild ${ROOTFS##*/} with script/get-kernel.sh or apply the overlay from
  multi-vm-explore/rootfs-overlay before testing this VM.
EOF
