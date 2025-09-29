#!/usr/bin/env bash
# liblog.sh — tiny logging helpers with timestamps and levels.
set -Eeuo pipefail
IFS=$'\n\t'

COMPONENT_NAME=${COMPONENT_NAME:-experiments-runner}
_ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log_info() {
	ts=$(_ts)
	echo "${ts} [INFO]  [${COMPONENT_NAME}] $*"
}
log_warn() {
	ts=$(_ts)
	echo "${ts} [WARN]  [${COMPONENT_NAME}] $*" >&2
}
log_error() {
	ts=$(_ts)
	echo "${ts} [ERROR] [${COMPONENT_NAME}] $*" >&2
}
log_debug() {
	ts=$(_ts)
	echo "${ts} [DEBUG] [${COMPONENT_NAME}] $*"
}
