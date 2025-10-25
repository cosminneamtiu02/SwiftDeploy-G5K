#!/usr/bin/env bash
# shellcheck shell=bash

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'logging.sh is a library and must be sourced.\n' >&2
	exit 1
fi

pipeline_logging__timestamp() {
	local dest_var="$1"
	local ts
	ts="$(date +"%H:%M:%S" 2>/dev/null || true)"
	printf -v "${dest_var}" '%s' "${ts}"
}

pipeline_logging__print() {
	local level="${1:-INFO}"
	if (($# > 0)); then
		shift
	fi
	local message="$*"
	local timestamp=""
	pipeline_logging__timestamp timestamp
	printf '[%s] [%s] %s\n' "${timestamp}" "${level}" "${message}" 2>/dev/null
	local print_status=$?
	if ((print_status != 0)); then
		return 0
	fi
	return 0
}

log_debug() {
	pipeline_logging__print "DEBUG" "$@"
}

log_info() {
	pipeline_logging__print "INFO" "$@"
}

log_warn() {
	pipeline_logging__print "WARN" "$@"
}

log_error() {
	pipeline_logging__print "ERROR" "$@"
}

log_success() {
	pipeline_logging__print "OK" "$@"
}

log_step() {
	pipeline_logging__print "STEP" "$@"
}

die() {
	log_error "$*"
	exit 1
}

pipeline_logging__bootstrap() {
	if [[ -n ${PIPELINE_LOGGING_BOOTSTRAPPED:-} ]]; then
		return 0
	fi

	local utils_root
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	if [[ -n ${UTILS_ROOT:-} ]]; then
		utils_root="${UTILS_ROOT}"
	else
		local default_utils_root
		default_utils_root="$(cd "${script_dir}/../support/utils" && pwd)"
		utils_root="${default_utils_root}"
	fi
	local liblog_path
	liblog_path="${utils_root}/liblog.sh"

	if [[ -f ${liblog_path} ]]; then
		# shellcheck source=experiments-runner/runtime/support/utils/liblog.sh
		source "${liblog_path}"
	fi

	PIPELINE_LOGGING_BOOTSTRAPPED=1
}
