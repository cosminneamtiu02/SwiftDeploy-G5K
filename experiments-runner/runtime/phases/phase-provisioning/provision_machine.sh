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

STATE_HEADER=$'# Machine provisioning state\n'

usage() {
	cat <<'EOF'
Usage:
  provision_machine.sh run --config <config-path> --log-dir <dir> --state-file <state-file>
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

phase_run() {
	local config_path=""
	local log_dir=""
	local state_file=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--config)
				config_path="$2"
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
			*)
				log_error "provision_machine.sh run: unknown argument $1"
				usage
				exit 1
				;;
		esac
	done
	if [[ -z ${config_path} || -z ${log_dir} || -z ${state_file} ]]; then
		die 'provision_machine.sh run requires --config, --log-dir, and --state-file.'
	fi

	local image_yaml
	image_yaml=$(jq -r '.machine_setup.image_to_use // empty' "${config_path}")
	if [[ -z ${image_yaml} ]]; then
		die 'Config missing .machine_setup.image_to_use'
	fi

	local is_manual
	is_manual=$(jq -r '.machine_setup.is_machine_instantiator_manual // true' "${config_path}")

	local inst_dir
	inst_dir="${PROVISIONING_ROOT}/machine-instantiator/on-fe"
	if [[ ! -d ${inst_dir} ]]; then
		die "Missing directory: ${inst_dir}"
	fi

	runner_env::ensure_directory "${log_dir}"
	log_step 'Provisioning machine on front-end'
	local inst_output=""
	if [[ ${is_manual} == 'true' ]]; then
		if ! inst_output=$("${inst_dir}/manual_instantiator.sh" "${image_yaml}" 2>&1); then
			printf '%s\n' "${inst_output}" >&2
			die 'Manual instantiation failed'
		fi
	else
		if ! inst_output=$("${inst_dir}/automatic_instantiator.sh" "${image_yaml}" 2>&1); then
			printf '%s\n' "${inst_output}" >&2
			die 'Automatic instantiation failed'
		fi
	fi

	# Relay instantiation logs to the caller
	if [[ -n ${inst_output} ]]; then
		printf '%s\n' "${inst_output}" | grep -v '^NODE_NAME=' || true
	fi

	local node_name
	node_name=$(printf '%s\n' "${inst_output}" | awk -F'=' '$1=="NODE_NAME" {print $2; exit}')
	if [[ -z ${node_name} ]]; then
		die 'Instantiation script did not return a node name.'
	fi

	log_info 'Target node selected in memory.'

	if [[ -n ${state_file} ]]; then
		write_state_file "${state_file}" \
			"IMAGE_YAML=${image_yaml}"
	fi

	printf '__RESULT__ NODE_NAME=%s\n' "${node_name}"
	printf '__RESULT__ IMAGE_YAML=%s\n' "${image_yaml}"
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
