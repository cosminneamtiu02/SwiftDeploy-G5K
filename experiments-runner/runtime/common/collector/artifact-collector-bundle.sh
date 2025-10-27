#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck source-path=..

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'artifact-collector-bundle.sh is a library and must be sourced.\n' >&2
	exit 1
fi

COLLECTOR_BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECTOR_COMMON_DIR="$(cd "${COLLECTOR_BUNDLE_DIR}/.." && pwd)"

if [[ -z ${PIPELINE_ENV_BOOTSTRAPPED:-} ]]; then
	pushd "${COLLECTOR_BUNDLE_DIR}" >/dev/null || exit 1
	# shellcheck source=experiments-runner/runtime/common/pipeline-environment.sh
	source ../pipeline-environment.sh
	popd >/dev/null || exit 1
fi
pipeline_env::bootstrap

PIPELINE_REMOTE_ROOT="${PIPELINE_REMOTE_ROOT:-$(cd "${COLLECTOR_COMMON_DIR}/remote" && pwd)}"

: "${PIPELINE_REMOTE_ROOT:?PIPELINE_REMOTE_ROOT must be set before sourcing collector bundle}"

# shellcheck source=experiments-runner/runtime/common/remote/remote.sh
source "${PIPELINE_REMOTE_ROOT}/remote.sh"

PIPELINE_ARTIFACT_REMOTE_TOOLS=(
	"pre-scan.sh"
	"enumerate.sh"
	"deep-diag.sh"
	"locator.sh"
	"snapshot.sh"
)

pipeline_artifact_bundle::deploy() {
	local node="${1:-}"
	if [[ -z ${node} ]]; then
		die 'pipeline_artifact_bundle::deploy expects a node name.'
	fi
	local bundle_dir="/tmp/swiftdeploy_pipeline_${USER}_$$"
	pipeline_file_transfer::remote_mkdir "${node}" "${bundle_dir}"
	local script
	for script in "${PIPELINE_ARTIFACT_REMOTE_TOOLS[@]}"; do
		local local_path
		local_path=$(pipeline_remote::tool_path "${script}")
		pipeline_remote::deploy_script "${node}" "${local_path}" "${bundle_dir}/${script}"
	done
	printf '%s\n' "${bundle_dir}"
}

pipeline_artifact_bundle::cleanup() {
	local node="${1:-}"
	local bundle_dir="${2:-}"
	if [[ -z ${node} || -z ${bundle_dir} ]]; then
		log_warn 'pipeline_artifact_bundle::cleanup invoked without node/bundle; skipping remote cleanup.'
		return 0
	fi
	local script
	for script in "${PIPELINE_ARTIFACT_REMOTE_TOOLS[@]}"; do
		pipeline_remote::cleanup_script "${node}" "${bundle_dir}/${script}"
	done
	pipeline_file_transfer::remove_remote_directory "${node}" "${bundle_dir}"
}
