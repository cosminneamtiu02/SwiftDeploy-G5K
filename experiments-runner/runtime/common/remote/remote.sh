#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source-path=..
# shellcheck source-path=../collector

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'remote.sh is a library and must be sourced.\n' >&2
	exit 1
fi

PIPELINE_REMOTE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z ${PIPELINE_ENV_BOOTSTRAPPED:-} ]]; then
	# shellcheck source=experiments-runner/runtime/common/pipeline-environment.sh
	source "${PIPELINE_REMOTE_DIR}/../pipeline-environment.sh"
fi
pipeline_env::bootstrap

: "${PIPELINE_COLLECTOR_ROOT:?PIPELINE_COLLECTOR_ROOT must be set before sourcing pipeline remote}"
: "${PIPELINE_PHASE_COLLECTION:?PIPELINE_PHASE_COLLECTION must be set before sourcing pipeline remote}"

# shellcheck source=experiments-runner/runtime/common/collector/file-transfer.sh
source "${PIPELINE_COLLECTOR_ROOT}/file-transfer.sh"

pipeline_remote::tool_path() {
	local script_name="${1:-}"
	if [[ -z ${script_name} ]]; then
		die 'pipeline_remote::tool_path requires a script name.'
	fi
	: "${PIPELINE_PHASE_COLLECTION:?PIPELINE_PHASE_COLLECTION must be set before calling pipeline_remote::tool_path}"
	printf '%s/%s' "${PIPELINE_PHASE_COLLECTION}/remote-tools" "${script_name}"
}

pipeline_remote::deploy_script() {
	local node="${1:-}"
	local local_path="${2:-}"
	local remote_path="${3:-}"
	if [[ -z ${node} || -z ${local_path} || -z ${remote_path} ]]; then
		die 'pipeline_remote::deploy_script expects node, local path, remote path.'
	fi
	pipeline_file_transfer::upload_script "${node}" "${local_path}" "${remote_path}"
}

pipeline_remote::run_script() {
	local node="${1:-}"
	local remote_path="${2:-}"
	shift 2 || true
	if [[ -z ${node} || -z ${remote_path} ]]; then
		die 'pipeline_remote::run_script expects node and remote path.'
	fi
	pipeline_file_transfer::run_remote_script "${node}" "${remote_path}" "$@"
}

pipeline_remote::cleanup_script() {
	local node="${1:-}"
	local remote_path="${2:-}"
	if [[ -z ${node} || -z ${remote_path} ]]; then
		die 'pipeline_remote::cleanup_script expects node and remote path.'
	fi
	pipeline_file_transfer::remove_remote_file "${node}" "${remote_path}"
}
