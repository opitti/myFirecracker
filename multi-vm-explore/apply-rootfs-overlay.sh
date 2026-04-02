#!/usr/bin/env bash

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <rootfs-dir>" >&2
    exit 1
fi

TARGET_ROOTFS_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="${SCRIPT_DIR}/rootfs-overlay"

if [ ! -d "${TARGET_ROOTFS_DIR}" ]; then
    echo "Missing rootfs directory: ${TARGET_ROOTFS_DIR}" >&2
    exit 1
fi

install -d "${TARGET_ROOTFS_DIR}/usr/local/bin"
install -d "${TARGET_ROOTFS_DIR}/etc"
install -d "${TARGET_ROOTFS_DIR}/app"

install -m 0755 "${OVERLAY_DIR}/usr/local/bin/fcnet-setup.sh" \
    "${TARGET_ROOTFS_DIR}/usr/local/bin/fcnet-setup.sh"
install -m 0644 "${OVERLAY_DIR}/etc/resolv.conf" \
    "${TARGET_ROOTFS_DIR}/etc/resolv.conf"
install -m 0644 "${OVERLAY_DIR}/app/.keep" \
    "${TARGET_ROOTFS_DIR}/app/.keep"
