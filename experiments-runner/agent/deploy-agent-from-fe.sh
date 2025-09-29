#!/usr/bin/env bash
# deploy-agent-from-fe.sh — FE-only installer for node-agent and on-machine assets via scp
set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

G5K_USER=${G5K_USER:?}
G5K_HOST=${G5K_HOST:?}
G5K_SSH_KEY=${G5K_SSH_KEY:?}

REMOTE_BASE="${HOME}/experiments_node"
REMOTE_ONM="${REMOTE_BASE}/on-machine"
REMOTE_COLLECTION="${REMOTE_ONM}/collection"

# shellcheck source=../bin/utils/libremote.sh
# shellcheck disable=SC1091
source "${ROOT_DIR}/bin/utils/libremote.sh"

echo "[INFO] Creating remote dirs via scp"
# Create a local skeleton tree and scp it to the remote base
tmpdir=$(mktemp -d)
mkdir -p "${tmpdir}/on-machine/bootstrap" \
	"${tmpdir}/on-machine/executables" \
	"${tmpdir}/on-machine/logs" \
	"${tmpdir}/on-machine/collection" \
	"${tmpdir}/control"
: >"${tmpdir}/.keep"
scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" "${tmpdir}/"* "${REMOTE_BASE}/"
rm -rf "${tmpdir}"

echo "[INFO] Uploading agent and on-machine assets"
scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" \
	"${SCRIPT_DIR}/node-agent.sh" "${REMOTE_BASE}/"

scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" \
	"${ROOT_DIR}/bin/experiments-delegator/on-machine/run-batch.sh" "${REMOTE_ONM}/"

if compgen -G "${ROOT_DIR}/bin/experiments-collector/on-machine/*.sh" >/dev/null; then
	scp_to_retry "${G5K_USER}" "${G5K_HOST}" "${G5K_SSH_KEY}" \
		"${ROOT_DIR}"/bin/experiments-collector/on-machine/*.sh "${REMOTE_COLLECTION}/"
fi

echo "[INFO] Agent deployed (start is handled by postinstall/systemd or manual run)."
