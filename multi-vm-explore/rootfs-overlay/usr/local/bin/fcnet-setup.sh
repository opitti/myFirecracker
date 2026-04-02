#!/usr/bin/env bash

set -euo pipefail

# Copyright 2021 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# The guest IP is derived from the Firecracker MAC address 06:00:xx:xx:xx:xx.
# For the multi-VM setup, all guests share 172.16.0.0/28 behind the host bridge.

NETWORK_MASK_SHORT="${FC_NETWORK_MASK_SHORT:-/28}"
DEFAULT_GW="${FC_DEFAULT_GW:-172.16.0.1}"
APP_BLOCK_DEV="${FC_APP_BLOCK_DEV:-/dev/vdb}"
APP_MOUNT_POINT="${FC_APP_MOUNT_POINT:-/app}"

configure_netdev() {
    local dev="$1"
    local mac_ip
    local ip

    mac_ip="$(ip link show dev "${dev}" \
        | grep link/ether \
        | grep -Po "(?<=06:00:)([0-9a-f]{2}:?){4}" \
        || true
    )"

    if [ -z "${mac_ip}" ]; then
        return 0
    fi

    ip="$(printf "%d.%d.%d.%d" $(echo "0x${mac_ip}" | sed "s/:/ 0x/g"))"
    ip addr replace "${ip}${NETWORK_MASK_SHORT}" dev "${dev}"
    ip link set "${dev}" up
    ip route replace default via "${DEFAULT_GW}" dev "${dev}"
}

mount_app_disk() {
    local dev_path

    if [ ! -b "${APP_BLOCK_DEV}" ]; then
        return 0
    fi

    mkdir -p "${APP_MOUNT_POINT}"
    dev_path="$(readlink -f "${APP_BLOCK_DEV}" || echo "${APP_BLOCK_DEV}")"

    blkid "${dev_path}" >/dev/null 2>&1 || mkfs.ext4 -F "${dev_path}"

    if ! mountpoint -q "${APP_MOUNT_POINT}"; then
        mount "${dev_path}" "${APP_MOUNT_POINT}"
    fi
}

main() {
    local dev

    for dev in /sys/class/net/*; do
        dev="$(basename "${dev}")"
        [ "${dev}" = "lo" ] && continue
        configure_netdev "${dev}"
    done

    mount_app_disk
}

main
