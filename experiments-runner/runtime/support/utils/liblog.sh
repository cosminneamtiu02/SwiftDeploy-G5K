#!/usr/bin/env bash
# Lightweight logging helpers with colors, levels, and optional file output.
# Usage: source this file, then use log_info, log_warn, log_error, log_success, log_debug, log_step.
# Optional env vars:
#   LOG_LEVEL: debug|info|warn|error (default: info)
#   LOG_FILE: path to a file to append logs
#   NO_COLOR: if set, disables colors
set -euo pipefail
IFS=$'\n\t'

# Ignore SIGPIPE so logging doesn't crash or spam on closed pipes
trap '' PIPE

__log_ts() { date +"%H:%M:%S" 2>/dev/null || true; }

__log_supports_color=false
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
	__log_supports_color=true
fi

__CLR_RESET=""
__CLR_DIM=""
__CLR_GREEN=""
__CLR_YELLOW=""
__CLR_RED=""
__CLR_BLUE=""
if ${__log_supports_color}; then
	__CLR_RESET='\033[0m'
	__CLR_DIM='\033[2m'
	__CLR_GREEN='\033[32m'
	__CLR_YELLOW='\033[33m'
	__CLR_RED='\033[31m'
	__CLR_BLUE='\033[34m'
fi

__LOG_LEVEL_STR="${LOG_LEVEL:-info}"
case "${__LOG_LEVEL_STR}" in
	debug) __LOG_LEVEL=10 ;;
	info) __LOG_LEVEL=20 ;;
	warn) __LOG_LEVEL=30 ;;
	error) __LOG_LEVEL=40 ;;
	*) __LOG_LEVEL=20 ;;
esac

__write_log() {
	# $1 level number, $2 colored level label, $3 message
	local lvl_num=$1
	shift
	local lvl_lbl=$1
	shift
	local msg=$*
	if ((lvl_num < __LOG_LEVEL)); then return 0; fi
	local ts
	ts=$(__log_ts)
	local line="[${ts}] ${lvl_lbl}${msg}${__CLR_RESET}"
	# stdout (ignore write errors if consumer closed the pipe)
	echo -e "${line}" 2>/dev/null || true
	# optional file
	if [[ -n ${LOG_FILE:-} ]]; then
		# strip colors for file
		echo "[${ts}] ${msg}" >>"${LOG_FILE}" 2>/dev/null || true
	fi
}

log_debug() { __write_log 10 "${__CLR_DIM}[DEBUG] " "$*"; }
log_info() { __write_log 20 "${__CLR_BLUE}[INFO]  " "$*"; }
log_warn() { __write_log 30 "${__CLR_YELLOW}[WARN]  " "$*"; }
log_error() { __write_log 40 "${__CLR_RED}[ERROR] " "$*"; }
log_success() { __write_log 20 "${__CLR_GREEN}[OK]    " "$*"; }
log_step() { __write_log 20 "${__CLR_GREEN}[STEP]  " "$*"; }

die() {
	log_error "$*"
	exit 1
}
