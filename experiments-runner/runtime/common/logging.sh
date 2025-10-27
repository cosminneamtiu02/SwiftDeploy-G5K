#!/usr/bin/env bash
# shellcheck shell=bash

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	printf 'logging.sh is a library and must be sourced.\n' >&2
	exit 1
fi

logging::bootstrap() {
	local utils_root="${1:-}"
	if [[ -z ${utils_root} ]]; then
		printf 'logging::bootstrap expects the utils directory path.\n' >&2
		exit 1
	fi
	if [[ -n ${LOGGING_BOOTSTRAPPED:-} ]]; then
		return 0
	fi
	local liblog_path="${utils_root}/liblog.sh"
	if [[ -f ${liblog_path} ]]; then
		# shellcheck source=experiments-runner/runtime/support/utils/liblog.sh
		source "${liblog_path}"
	else
		logging::__define_fallbacks
	fi
	LOGGING_BOOTSTRAPPED=1
}

logging::__define_fallbacks() {
	eval '
logging::__timestamp() { date +"%H:%M:%S" 2>/dev/null || true; }
log_debug() { printf "[%s] [DEBUG] %s\\n" "$(logging::__timestamp)" "$*" 2>/dev/null || true; }
log_info() { printf "[%s] [INFO]  %s\\n" "$(logging::__timestamp)" "$*" 2>/dev/null || true; }
log_warn() { printf "[%s] [WARN]  %s\\n" "$(logging::__timestamp)" "$*" 2>/dev/null || true; }
log_error() { printf "[%s] [ERROR] %s\\n" "$(logging::__timestamp)" "$*" 2>/dev/null || true; }
log_success() { printf "[%s] [OK]    %s\\n" "$(logging::__timestamp)" "$*" 2>/dev/null || true; }
log_step() { printf "[%s] [STEP]  %s\\n" "$(logging::__timestamp)" "$*" 2>/dev/null || true; }
die() {
	log_error "$*"
	exit 1
}
'
	export -f log_debug log_info log_warn log_error log_success log_step die
}
