#!/usr/bin/env bash

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'file_transfer.sh is a library and must be sourced.\n' >&2
	exit 1
fi

file_transfer::remote_mkdir() {
	local node="${1:-}"
	local path="${2:-}"
	ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${node}" "mkdir -p '${path}'" >/dev/null 2>&1
}

file_transfer::scp_to_node() {
	local src="${1:-}"
	local node="${2:-}"
	local dst="${3:-}"
	scp -q -o StrictHostKeyChecking=no -r "${src}" "root@${node}:${dst}"
}

file_transfer::scp_from_node() {
	local node="${1:-}"
	local remote_path="${2:-}"
	local local_path="${3:-}"
	scp -q -o StrictHostKeyChecking=no "root@${node}:${remote_path}" "${local_path}"
}

file_transfer::transfer_dir_tar() {
	local src_dir="${1:-}"
	local node="${2:-}"
	local dst_dir="${3:-}"
	if [[ ! -d ${src_dir} ]]; then
		die "transfer_dir_tar: source directory not found: ${src_dir}"
	fi
	ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${node}" "mkdir -p '${dst_dir}'" >/dev/null 2>&1 || die "Unable to create ${dst_dir} on ${node}"
	local archive_local=""
	archive_local=$(mktemp) || die 'transfer_dir_tar: failed to create temporary archive.'
	if ! tar -C "${src_dir}" -cf "${archive_local}" .; then
		rm -f "${archive_local}"
		die 'transfer_dir_tar: failed to create archive.'
	fi
	local archive_remote=""
	archive_remote="/tmp/transfer_dir.$(date +%s).tar"
	if ! scp -q -o StrictHostKeyChecking=no "${archive_local}" "root@${node}:${archive_remote}"; then
		rm -f "${archive_local}"
		die 'transfer_dir_tar: failed to upload archive to remote.'
	fi
	local extract_rc=0
	if ! ssh -o StrictHostKeyChecking=no "root@${node}" "tar -xf '${archive_remote}' -C '${dst_dir}' && rm -f '${archive_remote}'" >/dev/null 2>&1; then
		extract_rc=1
	fi
	rm -f "${archive_local}"
	if ((extract_rc != 0)); then
		die 'transfer_dir_tar: failed to extract archive on remote.'
	fi
}

file_transfer::upload_script() {
	local node="${1:-}"
	local local_script="${2:-}"
	local remote_path="${3:-}"
	file_transfer::scp_to_node "${local_script}" "${node}" "${remote_path}"
	ssh -o StrictHostKeyChecking=no "root@${node}" "chmod +x '${remote_path}'" >/dev/null 2>&1
}

file_transfer::run_remote_script() {
	local node="${1:-}"
	local remote_path="${2:-}"
	shift 2
	local -a env_vars=()
	local -a args=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--env)
				env_vars+=("$2")
				shift 2
				;;
			--)
				shift
				args=("$@")
				break
				;;
			*)
				args+=("$1")
				shift
				;;
		esac
	done
	local env_prefix=""
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
	ssh -o StrictHostKeyChecking=no "root@${node}" "${env_prefix}bash -lc ${cmd@Q}"
}
