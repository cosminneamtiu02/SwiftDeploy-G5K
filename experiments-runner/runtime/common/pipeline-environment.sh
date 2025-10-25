#!/usr/bin/env bash
# shellcheck shell=bash

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'pipeline-environment.sh is a library and must be sourced.\n' >&2
	exit 1
fi

_pipeline_env_bootstrap() {
	if [[ -n ${PIPELINE_ENV_BOOTSTRAPPED:-} ]]; then
		return 0
	fi

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

	if [[ -z ${RUNNER_ENV_BOOTSTRAPPED:-} ]]; then
		# shellcheck source=experiments-runner/runtime/common/environment.sh
		source "${script_dir}/environment.sh"
		runner_env::bootstrap
	fi

	local runtime_root="${RUNTIME_ROOT:?RUNTIME_ROOT must be set before sourcing pipeline-environment.sh}"
	local common_root="${COMMON_ROOT:?COMMON_ROOT must be set before sourcing pipeline-environment.sh}"
	local phase_root="${PHASE_ROOT:?PHASE_ROOT must be set before sourcing pipeline-environment.sh}"
	local collector_common_root="${COLLECTOR_COMMON_ROOT:?COLLECTOR_COMMON_ROOT must be set before sourcing pipeline-environment.sh}"
	local selection_root="${SELECTION_ROOT:?SELECTION_ROOT must be set before sourcing pipeline-environment.sh}"
	local provisioning_root="${PROVISIONING_ROOT:?PROVISIONING_ROOT must be set before sourcing pipeline-environment.sh}"
	local preparation_root="${PREPARATION_ROOT:?PREPARATION_ROOT must be set before sourcing pipeline-environment.sh}"
	local execution_root="${EXECUTION_ROOT:?EXECUTION_ROOT must be set before sourcing pipeline-environment.sh}"
	local collection_root="${COLLECTION_ROOT:?COLLECTION_ROOT must be set before sourcing pipeline-environment.sh}"

	PIPELINE_ROOT="${runtime_root}"
	export PIPELINE_ROOT
	PIPELINE_COMMON_ROOT="${common_root}"
	export PIPELINE_COMMON_ROOT
	PIPELINE_PHASE_ROOT="${phase_root}"
	export PIPELINE_PHASE_ROOT

	PIPELINE_LOGGING_ROOT="${common_root}/pipeline-logging"
	export PIPELINE_LOGGING_ROOT
	PIPELINE_COLLECTOR_ROOT="${collector_common_root}"
	export PIPELINE_COLLECTOR_ROOT
	PIPELINE_REMOTE_ROOT="${common_root}/remote"
	export PIPELINE_REMOTE_ROOT

	PIPELINE_PHASE_SELECTION="${selection_root}"
	export PIPELINE_PHASE_SELECTION
	PIPELINE_PHASE_PROVISIONING="${provisioning_root}"
	export PIPELINE_PHASE_PROVISIONING
	PIPELINE_PHASE_PREPARATION="${preparation_root}"
	export PIPELINE_PHASE_PREPARATION
	PIPELINE_PHASE_DELEGATION="${execution_root}"
	export PIPELINE_PHASE_DELEGATION
	PIPELINE_PHASE_COLLECTION="${collection_root}"
	export PIPELINE_PHASE_COLLECTION

	# shellcheck source=experiments-runner/runtime/common/pipeline-logging/logging.sh
	source "${PIPELINE_LOGGING_ROOT}/logging.sh"
	pipeline_logging__bootstrap

	PIPELINE_ENV_BOOTSTRAPPED=1
}

pipeline_env::bootstrap() {
	_pipeline_env_bootstrap
}
