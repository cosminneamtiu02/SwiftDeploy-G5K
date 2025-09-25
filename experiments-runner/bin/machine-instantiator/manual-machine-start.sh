#!/usr/bin/env bash
# manual-machine-start.sh
# Purpose: Guide manual instantiation on Grid'5000 and verify SSH connectivity.
# Inputs: JSON config via controller; environment variables G5K_USER, G5K_HOST, G5K_SSH_KEY.
# Exit codes: 0 success, 1 invalid env, 2 connectivity failure.

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO ${BASH_COMMAND}" >&2' ERR

usage() {
  cat <<EOF
manual-machine-start.sh --help

This script prints instructions for manual Grid'5000 instantiation and validates SSH access.

Environment expected after manual steps:
  G5K_USER     Grid'5000 username
  G5K_HOST     Target SSH host (e.g., node-1.site.grid5000.fr)
  G5K_SSH_KEY  Path to private key for SSH

Validation performed:
  ssh -o BatchMode=yes -i "$G5K_SSH_KEY" "$G5K_USER@$G5K_HOST" true

Exit codes:
  0 OK
  1 Missing env
  2 SSH connectivity failure
EOF
}

if [[ "${1:-}" == "--help" ]]; then usage; exit 0; fi

echo "[INFO] Manual instantiation selected. Please perform the following on Grid'5000:"
echo "  1) Reserve nodes with oarsub and wait for allocation."
echo "  2) Deploy the requested image (see machine_setup.image_to_use)."
echo "  3) Export the environment variables so downstream scripts can reach the node:"
echo "     export G5K_USER=your_user"
echo "     export G5K_HOST=node-1.site.grid5000.fr"
echo "     export G5K_SSH_KEY=~/.ssh/id_rsa"

echo "[INFO] Verifying environment variables..."
: "${G5K_USER:?G5K_USER is required}"
: "${G5K_HOST:?G5K_HOST is required}"
: "${G5K_SSH_KEY:?G5K_SSH_KEY is required}"

if [[ ! -f "$G5K_SSH_KEY" ]]; then
  echo "[ERROR] SSH key not found: $G5K_SSH_KEY" >&2
  exit 1
fi

echo "[INFO] Checking SSH connectivity to $G5K_USER@$G5K_HOST ..."
if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$G5K_SSH_KEY" "$G5K_USER@$G5K_HOST" true; then
  echo "[ERROR] Unable to SSH to $G5K_USER@$G5K_HOST" >&2
  exit 2
fi

echo "[INFO] Manual machine instantiation verified."
