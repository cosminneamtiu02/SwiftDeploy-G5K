#!/usr/bin/env bash
# liblog.sh — tiny logging helpers with timestamps and levels.
set -Eeuo pipefail
IFS=$'\n\t'

COMPONENT_NAME=${COMPONENT_NAME:-experiments-runner}
_ts() { date +"%Y-%m-%dT%H:%M:%S%z"; }
log_info()  { echo "$(
  _ts) [INFO]  [$COMPONENT_NAME] $*"; }
log_warn()  { echo "$(
  _ts) [WARN]  [$COMPONENT_NAME] $*" >&2; }
log_error() { echo "$(
  _ts) [ERROR] [$COMPONENT_NAME] $*" >&2; }
log_debug() { echo "$(
  _ts) [DEBUG] [$COMPONENT_NAME] $*"; }
