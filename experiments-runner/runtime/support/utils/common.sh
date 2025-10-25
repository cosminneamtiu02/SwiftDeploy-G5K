#!/usr/bin/env bash
# Common helpers used across scripts
set -Eeuo pipefail
IFS=$'\n\t'

# repo roots
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Try to use liblog if sourced by callers; fallback to simple echo
if ! declare -F log_info >/dev/null 2>&1; then
	log() {
		local ts
		ts=$(date +"%H:%M:%S")
		echo "[${ts}] $*"
	}
	err() { echo "ERROR: $*" >&2; }
else
	log() { log_info "$*"; }
	err() { log_error "$*"; }
fi

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

# Robust directory transfer preserving permissions using tar over staged archive copy
transfer_dir_via_tar() {
	local src_dir="$1"
	local node="$2"
	local dst_dir="$3"
	[[ -d ${src_dir} ]] || die "transfer_dir_via_tar: source dir not found: ${src_dir}"
	ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${node}" "mkdir -p '${dst_dir}'" >/dev/null 2>&1 || {
		echo "WARN: SSH not ready on ${node}. Can't create ${dst_dir}" >&2
		return 1
	}
	local archive_local
	archive_local=$(mktemp) || die 'transfer_dir_via_tar: failed to create temporary archive.'
	if ! (cd "${src_dir}" && tar -cf "${archive_local}" .); then
		rm -f "${archive_local}"
		die 'transfer_dir_via_tar: failed to create archive.'
	fi
	local archive_remote=""
	archive_remote="/tmp/support_transfer.$(date +%s).tar"
	if ! scp -o StrictHostKeyChecking=no "${archive_local}" "root@${node}:${archive_remote}" >/dev/null 2>&1; then
		rm -f "${archive_local}"
		echo "WARN: Failed to copy archive to ${node}" >&2
		return 1
	fi
	local extract_rc=0
	if ! ssh -o StrictHostKeyChecking=no "root@${node}" "tar -xf '${archive_remote}' -C '${dst_dir}' && rm -f '${archive_remote}'" >/dev/null 2>&1; then
		extract_rc=1
	fi
	rm -f "${archive_local}"
	if ((extract_rc != 0)); then
		echo "WARN: Failed to extract archive on ${node}" >&2
		return 1
	fi
	return 0
}
