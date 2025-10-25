#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source-path=SCRIPTDIR

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'remote.sh is a library and must be sourced.\n' >&2
	exit 1
fi

REMOTE_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "experiments-runner/runtime/common/file_transfer.sh" ]]; then
	# shellcheck source=experiments-runner/runtime/common/file_transfer.sh
	source "experiments-runner/runtime/common/file_transfer.sh"
else
	# shellcheck source=file_transfer.sh
	source "${REMOTE_MODULE_DIR}/file_transfer.sh"
fi

remote::tool_path() {
	local script_name="${1:-}"
	if [[ -z ${script_name} ]]; then
		die 'remote::tool_path requires a script name.'
	fi
	: "${REMOTE_TOOL_ROOT:?REMOTE_TOOL_ROOT must be defined before calling remote::tool_path}"
	printf '%s/%s' "${REMOTE_TOOL_ROOT}" "${script_name}"
}

remote::deploy_script() {
	local node="${1:-}"
	local local_path="${2:-}"
	local remote_path="${3:-}"
	file_transfer::upload_script "${node}" "${local_path}" "${remote_path}"
}

remote::run_script() {
	local node="${1:-}"
	local remote_path="${2:-}"
	shift 2
	file_transfer::run_remote_script "${node}" "${remote_path}" "$@"
}

remote::cleanup_script() {
	local node="${1:-}"
	local remote_path="${2:-}"
	ssh -o StrictHostKeyChecking=no "root@${node}" "rm -f '${remote_path}'" >/dev/null 2>&1 || true
}
