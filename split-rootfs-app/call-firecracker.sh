#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

TAP_DEV="tap0"
TAP_IP="172.16.0.1"
MASK_SHORT="/30"
API_SOCKET="/tmp/firecracker.socket"
LOGFILE="${ROOT_DIR}/firecracker.log"
ROOTFS="${ROOT_DIR}/ubuntu-24.04.ext4"
APPFS="${SCRIPT_DIR}/app-data.ext4"
APPFS_SIZE="${APPFS_SIZE:-2G}"

sudo ip link del "${TAP_DEV}" 2>/dev/null || true
sudo ip tuntap add dev "${TAP_DEV}" mode tap
sudo ip addr add "${TAP_IP}${MASK_SHORT}" dev "${TAP_DEV}"
sudo ip link set dev "${TAP_DEV}" up

sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
sudo iptables -P FORWARD ACCEPT

HOST_IFACE="$(ip -j route list default | jq -r '.[0].dev')"

sudo iptables -t nat -D POSTROUTING -o "${HOST_IFACE}" -j MASQUERADE || true
sudo iptables -t nat -A POSTROUTING -o "${HOST_IFACE}" -j MASQUERADE

if [ ! -f "${ROOTFS}" ]; then
    echo "Root filesystem not found: ${ROOTFS}" >&2
    exit 1
fi

if [ ! -f "${APPFS}" ]; then
    echo "Creating persistent app disk: ${APPFS} (${APPFS_SIZE})"
    truncate -s "${APPFS_SIZE}" "${APPFS}"
    mkfs.ext4 -F "${APPFS}"
fi

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"log_path\": \"${LOGFILE}\",
        \"level\": \"Debug\",
        \"show_level\": true,
        \"show_log_origin\": true
    }" \
    "http://localhost/logger"

KERNEL="${ROOT_DIR}/$(ls "${ROOT_DIR}"/vmlinux* | tail -1 | xargs basename)"
KERNEL_BOOT_ARGS="console=ttyS0 reboot=k panic=1"
ARCH="$(uname -m)"

if [ "${ARCH}" = "aarch64" ]; then
    KERNEL_BOOT_ARGS="keep_bootcon ${KERNEL_BOOT_ARGS}"
fi

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
        \"is_read_only\": false
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

FC_MAC="06:00:AC:10:00:02"

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"iface_id\": \"net1\",
        \"guest_mac\": \"${FC_MAC}\",
        \"host_dev_name\": \"${TAP_DEV}\"
    }" \
    "http://localhost/network-interfaces/net1"

sleep 0.015s

sudo curl -X PUT --unix-socket "${API_SOCKET}" \
    --data "{
        \"action_type\": \"InstanceStart\"
    }" \
    "http://localhost/actions"

sleep 2s

KEY_NAME="${ROOT_DIR}/$(ls "${ROOT_DIR}"/*.id_rsa | tail -1 | xargs basename)"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${KEY_NAME}")
GUEST_IP="172.16.0.2"

ssh "${SSH_OPTS[@]}" root@"${GUEST_IP}" "ip route add default via 172.16.0.1 dev eth0 || true"
ssh "${SSH_OPTS[@]}" root@"${GUEST_IP}" "echo 'nameserver 8.8.8.8' > /etc/resolv.conf"

# The second virtio block device is mounted on /app and persists across VM restarts.
ssh "${SSH_OPTS[@]}" root@"${GUEST_IP}" \
    "mkdir -p /app && \
    DEV=\$(readlink -f /dev/vdb || echo /dev/vdb) && \
    blkid \"\${DEV}\" >/dev/null 2>&1 || mkfs.ext4 -F \"\${DEV}\" && \
    mount | grep -q ' on /app ' || mount \"\${DEV}\" /app"

ssh "${SSH_OPTS[@]}" root@"${GUEST_IP}"
