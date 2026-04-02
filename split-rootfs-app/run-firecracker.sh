#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
API_SOCKET="/tmp/firecracker.socket"

sudo rm -f "${API_SOCKET}"
sudo "${ROOT_DIR}/firecracker" --api-sock "${API_SOCKET}" --enable-pci
