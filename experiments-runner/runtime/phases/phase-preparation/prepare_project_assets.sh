#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source-path=../../common
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMMON_DIR="${RUNTIME_DIR}/common"

# shellcheck source=experiments-runner/runtime/common/environment.sh
source "${COMMON_DIR}/environment.sh"
runner_env::bootstrap

runner_env::require_cmd jq

STATE_HEADER=$'# Project preparation state\n'

usage() {
	cat <<'EOF'
Usage:
  prepare_project_assets.sh run --config <config> --node <hostname> --image-yaml <yaml> \
    --selected-b64 <base64> --log-dir <dir> --state-file <state>
EOF
}

write_state_file() {
	local state_file="${1:-}"
	shift
	{
		printf '%s' "${STATE_HEADER}"
		while (($# > 0)); do
			printf '%s\n' "$1"
			shift
		done
	} >"${state_file}"
}

wait_for_ssh() {
	local host="${1:-}"
	local timeout="${2:-600}"
	local start
	local now
	start=$(date +%s)
	while true; do
		if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${host}" 'echo ok' >/dev/null 2>&1; then
			return 0
		fi
		now=$(date +%s)
		if (((now - start) > timeout)); then
			return 1
		fi
		sleep 3
	done
}

phase_run() {
	local config_path=""
	local node_name=""
	local selected_b64=""
	local log_dir=""
	local state_file=""
	local image_yaml=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--config)
				config_path="$2"
				shift 2
				;;
			--node)
				node_name="$2"
				shift 2
				;;
			--selected-b64)
				selected_b64="$2"
				shift 2
				;;
			--log-dir)
				log_dir="$2"
				shift 2
				;;
			--state-file)
				state_file="$2"
				shift 2
				;;
			--image-yaml)
				image_yaml="$2"
				shift 2
				;;
			*)
				log_error "prepare_project_assets.sh run: unknown argument $1"
				usage
				exit 1
				;;
		esac
	done
	if [[ -z ${config_path} || -z ${node_name} || -z ${log_dir} || -z ${state_file} || -z ${image_yaml} ]]; then
		die 'prepare_project_assets.sh run requires --config, --node, --log-dir, --state-file, and --image-yaml.'
	fi

	runner_env::ensure_directory "${log_dir}"
	local os_dist
	os_dist=$(jq -r '.machine_setup.os_distribution_type // 1' "${config_path}")

	log_step 'Preparing project assets on front-end'
	if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${node_name}" 'echo ok' >/dev/null 2>&1; then
		if command -v kadeploy3 >/dev/null 2>&1; then
			log_warn "SSH not ready on ${node_name}. Deploying image via kadeploy3..."
			if ! kadeploy3 -a "${HOME}/envs/img-files/${image_yaml}" -m "${node_name}"; then
				die "kadeploy3 failed for ${node_name}."
			fi
			log_info "Waiting for SSH to come up on ${node_name}..."
			local ssh_wait_rc=0
			set +e
			wait_for_ssh "${node_name}" 900
			ssh_wait_rc=$?
			set -e
			if ((ssh_wait_rc != 0)); then
				die "Timed out waiting for SSH on ${node_name}."
			fi
			log_success "SSH is now available on ${node_name}."
		else
			log_warn "kadeploy3 not available; deploy manually: kadeploy3 -a ${HOME}/envs/img-files/${image_yaml} -m ${node_name}"
		fi
	fi

	local prep_fe_dir
	prep_fe_dir="${PREPARATION_ROOT}/project-preparation/on-fe"
	"${prep_fe_dir}/prepare_on_fe.sh" \
		--node "${node_name}" \
		--config "${config_path}" \
		--os-type "${os_dist}" \
		--logs "${log_dir}"

	local remote_log
	remote_log="${log_dir}/prepare_on_machine.log"
	if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${node_name}" 'echo ok' >/dev/null 2>&1; then
		log_info 'Executing on-node preparation script'
		LOG_FILE="${remote_log}" ssh -o StrictHostKeyChecking=no "root@${node_name}" \
			"bash -lc 'export SELECTED_PARAMS_B64=${selected_b64:-}; ~/experiments_node/on-machine/prepare_on_machine.sh'"
	else
		log_warn 'SSH not available. Please run on the node: ~/experiments_node/on-machine/prepare_on_machine.sh'
	fi

	write_state_file "${state_file}" \
		"REMOTE_PREP_LOG=${remote_log}" \
		"OS_DIST=${os_dist}"
}

main() {
	case "${1:-}" in
		run)
			shift
			phase_run "$@"
			;;
		*)
			usage
			exit 1
			;;
	esac
}

main "$@"
