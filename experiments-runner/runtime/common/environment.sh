#!/usr/bin/env bash
# shellcheck shell=bash

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'environment.sh is a library and must be sourced.\n' >&2
	exit 1
fi

_runner_env_bootstrap() {
	if [[ -n ${RUNNER_ENV_BOOTSTRAPPED:-} ]]; then
		return 0
	fi

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local runtime_dir
	runtime_dir="$(cd "${script_dir}/.." && pwd)"

	local runner_root
	runner_root="$(cd "${runtime_dir}/.." && pwd)"
	local repo_root
	repo_root="$(cd "${runner_root}/.." && pwd)"

	RUNNER_ROOT="${runner_root}"
	export RUNNER_ROOT
	REPO_ROOT="${repo_root}"
	export REPO_ROOT
	RUNTIME_ROOT="${runtime_dir}"
	export RUNTIME_ROOT

	# Backwards compatibility for scripts that still reference BIN_ROOT.
	BIN_ROOT="${RUNTIME_ROOT}"
	export BIN_ROOT

	COMMON_ROOT="${RUNTIME_ROOT}/common"
	export COMMON_ROOT
	SUPPORT_ROOT="${RUNTIME_ROOT}/support"
	export SUPPORT_ROOT
	PHASE_ROOT="${RUNTIME_ROOT}/phases"
	export PHASE_ROOT
	LOG_ROOT="${RUNNER_ROOT}/logs"
	export LOG_ROOT
	UTILS_ROOT="${SUPPORT_ROOT}/utils"
	export UTILS_ROOT
	SELECTION_ROOT="${PHASE_ROOT}/phase-selection"
	export SELECTION_ROOT
	PROVISIONING_ROOT="${PHASE_ROOT}/phase-provisioning"
	export PROVISIONING_ROOT
	PREPARATION_ROOT="${PHASE_ROOT}/phase-preparation"
	export PREPARATION_ROOT
	EXECUTION_ROOT="${PHASE_ROOT}/phase-delegation"
	export EXECUTION_ROOT
	COLLECTION_ROOT="${PHASE_ROOT}/phase-collection"
	export COLLECTION_ROOT
	REMOTE_TOOL_ROOT="${COLLECTION_ROOT}/remote-tools"
	export REMOTE_TOOL_ROOT
	COLLECTOR_COMMON_ROOT="${COMMON_ROOT}/collector"
	export COLLECTOR_COMMON_ROOT

	# shellcheck source=experiments-runner/runtime/common/logging.sh
	source "${COMMON_ROOT}/logging.sh"
	logging::bootstrap "${UTILS_ROOT}"

	RUNNER_ENV_BOOTSTRAPPED=1
}

runner_env::bootstrap() {
	_runner_env_bootstrap
}

runner_env::require_cmd() {
	local command_name="${1:-}"
	if [[ -z ${command_name} ]]; then
		printf 'runner_env::require_cmd expects a command name.\n' >&2
		exit 1
	fi
	if ! command -v "${command_name}" >/dev/null 2>&1; then
		printf 'Missing required command: %s\n' "${command_name}" >&2
		exit 1
	fi
}

runner_env::ensure_directory() {
	local target_dir="${1:-}"
	if [[ -z ${target_dir} ]]; then
		printf 'runner_env::ensure_directory expects a directory path.\n' >&2
		exit 1
	fi
	mkdir -p "${target_dir}" 2>/dev/null || {
		printf 'Failed to create directory: %s\n' "${target_dir}" >&2
		exit 1
	}
}
