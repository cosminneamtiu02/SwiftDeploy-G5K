#!/usr/bin/env bash
# Common helpers used across scripts
set -euo pipefail
IFS=$'\n\t'

# repo roots
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC2034 # REPO_ROOT available for callers
REPO_ROOT="$(cd "${RUNNER_ROOT}/.." && pwd)"

log() {
	local ts
	ts=$(date +"%H:%M:%S")
	echo "[${ts}] $*"
}
err() { echo "ERROR: $*" >&2; }

die() {
	err "$*"
	exit 1
}

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# Resolve FE path for params relative to experiments-runner/params unless absolute
resolve_params_path() {
	local p="$1"
	if [[ ${p} == /* ]]; then
		echo "${p}"
	else
		echo "${RUNNER_ROOT}/params/${p}"
	fi
}

# Ensure a directory exists on remote via scp-only workflow by sending a small script
remote_mkdir_via_ssh() {
	local node="$1"
	shift
	local path="$1"
	shift
	# Try SSH non-interactively first
	if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${node}" "mkdir -p '${path}'" >/dev/null 2>&1; then
		return 0
	fi
	# If that fails, hint at deploy readiness; the caller should ensure kadeploy is done
	echo "WARN: SSH not ready on ${node}. Ensure the node is deployed and reachable." >&2
	return 1
}

safe_scp_to_node() {
	local src="$1"
	shift
	local node="$1"
	shift
	local dst="$1"
	shift
	scp -o StrictHostKeyChecking=no -r "${src}" "root@${node}:${dst}"
}
