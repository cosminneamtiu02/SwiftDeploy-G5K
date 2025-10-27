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

STATE_HEADER=$'# Delegation state\n'

usage() {
	cat <<'EOF'
Usage:
  delegate_experiments.sh run --node <hostname> --selected-b64 <base64> --log-dir <dir> --state-file <state>
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
	local node_name=""
	local selected_b64=""
	local log_dir=""
	local state_file=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
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
			*)
				log_error "delegate_experiments.sh run: unknown argument $1"
				usage
				exit 1
				;;
		esac
	done
	if [[ -z ${node_name} || -z ${selected_b64} || -z ${log_dir} || -z ${state_file} ]]; then
		die 'delegate_experiments.sh run requires --node, --selected-b64, --log-dir, and --state-file.'
	fi

	runner_env::ensure_directory "${log_dir}"
	log_step "Delegating experiments on ${node_name}"

	if ! ssh -o StrictHostKeyChecking=no "root@${node_name}" 'echo ok' >/dev/null 2>&1; then
		die "SSH not available on ${node_name}."
	fi

	local delegator_cmd
	delegator_cmd=$'export SELECTED_PARAMS_B64='${selected_b64}$'; CONFIG_JSON=~/experiments_node/config.json; \
if command -v stdbuf >/dev/null 2>&1; then \
  stdbuf -oL -eL ~/experiments_node/on-machine/run_delegator.sh; \
else \
  ~/experiments_node/on-machine/run_delegator.sh; \
fi'

	local deleg_rc
	set +o pipefail
	set +e
	ssh -o StrictHostKeyChecking=no "root@${node_name}" "bash -lc ${delegator_cmd@Q}" 2>&1 |
		while IFS= read -r line; do
			local ts
			ts=$(date +"%H:%M:%S" 2>/dev/null || true)
			printf '[%s] [INFO]  [%s] %s\n' "${ts}" "${node_name}" "${line}"
		done
	deleg_rc=${PIPESTATUS[0]}
	set -e
	set -o pipefail

	if [[ ${deleg_rc} -ne 0 ]]; then
		log_warn "Delegator failed (rc=${deleg_rc})."
	else
		log_success 'Delegation completed successfully.'
	fi

	write_state_file "${state_file}" \
		"DELEGATION_RC=${deleg_rc}" \
		"NODE_NAME=${node_name}"

	return "${deleg_rc}"
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
