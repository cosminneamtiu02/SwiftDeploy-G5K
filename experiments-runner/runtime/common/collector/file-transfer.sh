#!/usr/bin/env bash
# shellcheck shell=bash

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'file-transfer.sh is a library and must be sourced.\n' >&2
	exit 1
fi

COLLECTOR_FILE_TRANSFER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z ${PIPELINE_ENV_BOOTSTRAPPED:-} ]]; then
	# shellcheck source=experiments-runner/runtime/common/pipeline-environment.sh
	source "${COLLECTOR_FILE_TRANSFER_DIR}/../pipeline-environment.sh"
fi
pipeline_env::bootstrap

: "${PIPELINE_REMOTE_ROOT:?PIPELINE_REMOTE_ROOT must be set before using collector file-transfer}"

pipeline_file_transfer__ssh() {
	local node="${1:-}"
	shift
	ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${node}" "$@"
}

pipeline_file_transfer__scp() {
	local direction="${1:-}"
	shift
	local src dst node
	case "${direction}" in
		to)
			src="${1:-}"
			node="${2:-}"
			dst="${3:-}"
			scp -q -o StrictHostKeyChecking=no -r "${src}" "root@${node}:${dst}"
			;;
		from)
			node="${1:-}"
			src="${2:-}"
			dst="${3:-}"
			scp -q -o StrictHostKeyChecking=no "root@${node}:${src}" "${dst}"
			;;
		*)
			die "pipeline_file_transfer__scp direction must be 'to' or 'from'."
			;;
	esac
}

pipeline_file_transfer::remote_mkdir() {
	local node="${1:-}"
	local path="${2:-}"
	if [[ -z ${node} || -z ${path} ]]; then
		die 'pipeline_file_transfer::remote_mkdir expects node and path.'
	fi
	pipeline_file_transfer__ssh "${node}" "mkdir -p '${path}'" >/dev/null 2>&1
}

pipeline_file_transfer::scp_to_node() {
	local src="${1:-}"
	local node="${2:-}"
	local dst="${3:-}"
	if [[ -z ${src} || -z ${node} || -z ${dst} ]]; then
		die 'pipeline_file_transfer::scp_to_node expects src, node, dst.'
	fi
	pipeline_file_transfer__scp to "${src}" "${node}" "${dst}"
}

pipeline_file_transfer::scp_from_node() {
	local node="${1:-}"
	local remote_path="${2:-}"
	local local_path="${3:-}"
	if [[ -z ${node} || -z ${remote_path} || -z ${local_path} ]]; then
		die 'pipeline_file_transfer::scp_from_node expects node, remote path, local path.'
	fi
	pipeline_file_transfer__scp from "${node}" "${remote_path}" "${local_path}"
}

pipeline_file_transfer::transfer_dir_tar() {
	local src_dir="${1:-}"
	local node="${2:-}"
	local dst_dir="${3:-}"
	if [[ -z ${src_dir} || -z ${node} || -z ${dst_dir} ]]; then
		die 'pipeline_file_transfer::transfer_dir_tar expects src dir, node, dst dir.'
	fi
	if [[ ! -d ${src_dir} ]]; then
		die "pipeline_file_transfer::transfer_dir_tar source not found: ${src_dir}"
	fi
	local mkdir_rc=0
	set +e
	pipeline_file_transfer__ssh "${node}" "mkdir -p '${dst_dir}'" >/dev/null 2>&1
	mkdir_rc=$?
	set -e
	if ((mkdir_rc != 0)); then
		die "Unable to create ${dst_dir} on ${node}"
	fi
	local archive_local=""
	archive_local=$(mktemp) || die 'Failed to create temporary archive for transfer.'
	local cleanup_rc=0
	if ! tar -C "${src_dir}" -cf "${archive_local}" .; then
		rm -f "${archive_local}"
		die 'Failed to create archive for transfer.'
	fi
	local archive_remote=""
	archive_remote="/tmp/collector_transfer.$(date +%s).tar"
	if ! scp -q -o StrictHostKeyChecking=no "${archive_local}" "root@${node}:${archive_remote}"; then
		rm -f "${archive_local}"
		die 'Failed to copy archive to remote node.'
	fi
	set +e
	pipeline_file_transfer__ssh "${node}" "tar -xf '${archive_remote}' -C '${dst_dir}' && rm -f '${archive_remote}'" >/dev/null 2>&1
	cleanup_rc=$?
	set -e
	rm -f "${archive_local}"
	if ((cleanup_rc != 0)); then
		die 'Failed to extract archive on remote node.'
	fi
}

pipeline_file_transfer::upload_script() {
	local node="${1:-}"
	local local_script="${2:-}"
	local remote_path="${3:-}"
	if [[ -z ${node} || -z ${local_script} || -z ${remote_path} ]]; then
		die 'pipeline_file_transfer::upload_script expects node, local script, remote path.'
	fi
	pipeline_file_transfer::scp_to_node "${local_script}" "${node}" "${remote_path}"
	pipeline_file_transfer__ssh "${node}" "chmod +x '${remote_path}'" >/dev/null 2>&1
}

pipeline_file_transfer::remove_remote_file() {
	local node="${1:-}"
	local remote_path="${2:-}"
	if [[ -z ${node} || -z ${remote_path} ]]; then
		die 'pipeline_file_transfer::remove_remote_file expects node and remote path.'
	fi
	set +e
	pipeline_file_transfer__ssh "${node}" "rm -f '${remote_path}'" >/dev/null 2>&1
	set -e
}

pipeline_file_transfer::remove_remote_directory() {
	local node="${1:-}"
	local remote_dir="${2:-}"
	if [[ -z ${node} || -z ${remote_dir} ]]; then
		die 'pipeline_file_transfer::remove_remote_directory expects node and directory path.'
	fi
	set +e
	pipeline_file_transfer__ssh "${node}" "rmdir '${remote_dir}'" >/dev/null 2>&1
	set -e
}

pipeline_file_transfer::run_remote_script() {
	local node="${1:-}"
	local remote_path="${2:-}"
	shift 2 || true
	if [[ -z ${node} || -z ${remote_path} ]]; then
		die 'pipeline_file_transfer::run_remote_script expects node and remote path.'
	fi
	local -a env_vars=()
	local -a args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--env)
				if [[ $# -lt 2 ]]; then
					die 'pipeline_file_transfer::run_remote_script --env requires a KEY=VALUE pair.'
				fi
				env_vars+=("$2")
				shift 2
				;;
			--)
				shift
				while [[ $# -gt 0 ]]; do
					args+=("$1")
					shift
				done
				break
				;;
			*)
				args+=("$1")
				shift
				;;
		esac
	done
	local env_prefix=""
	local kv
	for kv in "${env_vars[@]}"; do
		env_prefix+="${kv} "
	done
	local quoted_path
	quoted_path=$(printf '%q' "${remote_path}")
	local cmd="${quoted_path}"
	local arg
	for arg in "${args[@]}"; do
		cmd+=" $(printf '%q' "${arg}")"
	done
	pipeline_file_transfer__ssh "${node}" "${env_prefix}bash -lc ${cmd@Q}"
}
