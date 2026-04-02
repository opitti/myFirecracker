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
STATE_DIR="${SCRIPT_DIR}/state"
VMS_DIR="${STATE_DIR}/vms"
LOCK_DIR="${STATE_DIR}/.lock"
VM_DIR="${VMS_DIR}/${VM_ID}"
META_FILE="${VM_DIR}/vm.env"
API_SOCKET="${VM_DIR}/firecracker.socket"
APPFS="${VM_DIR}/app-data.ext4"
APPFS_SIZE="${APPFS_SIZE:-100M}"
FIRECRACKER_BIN="${ROOT_DIR}/firecracker"
ROOTFS="${ROOT_DIR}/ubuntu-24.04.ext4"

mkdir -p "${VMS_DIR}"

acquire_lock() {
    while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
        sleep 0.1
    done
}

release_lock() {
    rmdir "${LOCK_DIR}" 2>/dev/null || true
}

trap release_lock EXIT
acquire_lock

if [ ! -x "${FIRECRACKER_BIN}" ]; then
    echo "Missing Firecracker binary: ${FIRECRACKER_BIN}" >&2
    exit 1
fi

if [ ! -f "${ROOTFS}" ]; then
    echo "Missing rootfs: ${ROOTFS}" >&2
    exit 1
fi

if [ -f "${META_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${META_FILE}"
else
    mkdir -p "${VM_DIR}"

    used_ips=" "
    for env_file in "${VMS_DIR}"/*/vm.env; do
        [ -f "${env_file}" ] || continue
        ip="$(grep '^GUEST_IP=' "${env_file}" | cut -d= -f2 || true)"
        if [ -n "${ip}" ]; then
            used_ips="${used_ips}${ip} "
        fi
    done

    GUEST_IP=""
    for last_octet in $(seq 2 14); do
        candidate_ip="172.16.0.${last_octet}"
        if [[ "${used_ips}" != *" ${candidate_ip} "* ]]; then
            GUEST_IP="${candidate_ip}"
            break
        fi
    done

    if [ -z "${GUEST_IP}" ]; then
        echo "No free guest IP left in 172.16.0.0/28" >&2
        exit 1
    fi

    GUEST_LAST_OCTET="${GUEST_IP##*.}"
    GUEST_MAC="$(printf '06:00:ac:10:00:%02x' "${GUEST_LAST_OCTET}")"
    TAP_DEV="fctap${GUEST_LAST_OCTET}"
    LOGFILE="${VM_DIR}/firecracker.log"
    KEY_NAME="${ROOT_DIR}/ubuntu-24.04.id_rsa"

    cat > "${META_FILE}" <<EOF
VM_ID=${VM_ID}
VM_DIR=${VM_DIR}
API_SOCKET=${API_SOCKET}
ROOTFS=${ROOTFS}
APPFS=${APPFS}
APPFS_SIZE=${APPFS_SIZE}
LOGFILE=${LOGFILE}
KEY_NAME=${KEY_NAME}
GUEST_IP=${GUEST_IP}
GUEST_MAC=${GUEST_MAC}
GUEST_LAST_OCTET=${GUEST_LAST_OCTET}
TAP_DEV=${TAP_DEV}
BRIDGE_DEV=fcbr0
HOST_IP=172.16.0.1
NETWORK_CIDR=172.16.0.0/28
NETWORK_MASK_SHORT=/28
EOF
fi

# shellcheck disable=SC1090
source "${META_FILE}"

if [ ! -f "${APPFS}" ]; then
    truncate -s "${APPFS_SIZE}" "${APPFS}"
    mkfs.ext4 -F "${APPFS}" >/dev/null
fi

rm -f "${API_SOCKET}"

cat <<EOF
VM ${VM_ID}
  socket: ${API_SOCKET}
  guest_ip: ${GUEST_IP}
  guest_mac: ${GUEST_MAC}
  app_disk: ${APPFS}

Guest rootfs reminder:
  Rebuild ${ROOTFS##*/} with script/get-kernel.sh or apply the overlay from
  multi-vm-explore/rootfs-overlay before testing multi-VM.
EOF

release_lock
trap - EXIT
exec sudo "${FIRECRACKER_BIN}" --api-sock "${API_SOCKET}" --enable-pci
