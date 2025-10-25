# TEST SHEBANG
# shellcheck shell=bash
# shellcheck source-path=..

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'collector-config.sh is a library and must be sourced.\n' >&2
	exit 1
fi

COLLECTOR_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z ${PIPELINE_ENV_BOOTSTRAPPED:-} ]]; then
	# shellcheck source=experiments-runner/runtime/common/pipeline-environment.sh
	source "${COLLECTOR_CONFIG_DIR}/../pipeline-environment.sh"
fi
pipeline_env::bootstrap

# shellcheck source=experiments-runner/runtime/common/collector.sh
source "${COLLECTOR_CONFIG_DIR}/../collector.sh"

: "${PIPELINE_COLLECTOR_ROOT:?PIPELINE_COLLECTOR_ROOT must be set before using collector config}"

if [[ -z ${PIPELINE_COLLECTOR_PREREQS:-} ]]; then
	pipeline_env::require_command jq
	PIPELINE_COLLECTOR_PREREQS=1
fi

pipeline_collector::load_config() {
	collector::load_config "$@"
}

pipeline_collector::validate_config() {
	collector::validate_config "$@"
}

pipeline_collector::build_rule_map() {
	collector::build_rule_map "$@"
}

pipeline_collector::transfer_count() {
	collector::transfer_count "$@"
}

pipeline_collector::get_transfer() {
	collector::get_transfer "$@"
}

pipeline_collector::patterns_from_labels() {
	collector::patterns_from_labels "$@"
}
