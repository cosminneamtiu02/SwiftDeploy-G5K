#!/usr/bin/env bash

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'artifact-state.sh is a library and must be sourced.\n' >&2
	exit 1
fi

COLLECTOR_STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z ${PIPELINE_ENV_BOOTSTRAPPED:-} ]]; then
	# shellcheck source=experiments-runner/runtime/common/pipeline-environment.sh
	source "${COLLECTOR_STATE_DIR}/../pipeline-environment.sh"
fi
pipeline_env::bootstrap

PIPELINE_ARTIFACT_STATE_HEADER="# Artifact collection state"

pipeline_artifact_state::write() {
	local state_file="${1:-}"
	shift || true
	if [[ -z ${state_file} ]]; then
		die 'pipeline_artifact_state::write expects a destination file.'
	fi
	{
		printf '%s\n' "${PIPELINE_ARTIFACT_STATE_HEADER}"
		while (($# > 0)); do
			printf '%s\n' "$1"
			shift
		done
	} >"${state_file}"
}
