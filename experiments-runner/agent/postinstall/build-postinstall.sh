#!/usr/bin/env bash
# Build a kadeploy postinstall tarball that installs and enables the node agent at boot
set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="${SCRIPT_DIR}/build"
OUT_TGZ="${OUT_DIR}/agent-postinstall.tgz"

mkdir -p "${OUT_DIR}"
tmpdir=$(mktemp -d)
cleanup() { rm -rf "${tmpdir}"; }
trap cleanup EXIT

# Layout expected by kadeploy postinstall: a top-level executable file named 'postinstall'
mkdir -p "${tmpdir}/files"
cp "${ROOT_DIR}/agent/node-agent.sh" "${tmpdir}/files/node-agent.sh"
cat >"${tmpdir}/postinstall" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

# Determine a regular user (uid >= 1000)
USER_NAME="$(awk -F: '$3>=1000 && $1!="nobody"{print $1; exit}' /etc/passwd)"
if [ -z "${USER_NAME}" ]; then
  echo "No suitable non-system user found; using root" >&2
  USER_NAME=root
fi
HOME_DIR="$(getent passwd "${USER_NAME}" | cut -d: -f6)"
mkdir -p "${HOME_DIR}/experiments_node/on-machine/bootstrap" \
         "${HOME_DIR}/experiments_node/on-machine/executables" \
         "${HOME_DIR}/experiments_node/on-machine/logs" \
         "${HOME_DIR}/experiments_node/on-machine/results" \
         "${HOME_DIR}/experiments_node/on-machine/collection" \
         "${HOME_DIR}/experiments_node/control"
install -m 0755 files/node-agent.sh "${HOME_DIR}/experiments_node/node-agent.sh"
chown -R "${USER_NAME}:" "${HOME_DIR}/experiments_node"

# Install systemd unit to start agent on boot as the user
cat >/etc/systemd/system/node-agent.service <<UNIT
[Unit]
Description=SwiftDeploy Node Agent
After=network.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${HOME_DIR}
ExecStart=/bin/bash -lc '${HOME_DIR}/experiments_node/node-agent.sh'
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload || true
systemctl enable node-agent.service || true
# Service will start on next boot; attempt to start now as well (if in target env)
systemctl start node-agent.service || true
EOS

chmod +x "${tmpdir}/postinstall"
tar -C "${tmpdir}" -czf "${OUT_TGZ}" postinstall files
echo "${OUT_TGZ}"
