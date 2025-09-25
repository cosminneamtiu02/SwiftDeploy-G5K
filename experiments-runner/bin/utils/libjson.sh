#!/usr/bin/env bash
# libjson.sh — safe jq wrappers & helpers
set -Eeuo pipefail
IFS=$'\n\t'

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq is required for JSON parsing." >&2
    exit 1
  fi
}

json_get() {
  # $1: json_file, $2: jq_filter
  require_jq
  local f="$1"; shift
  local q="$1"; shift || true
  jq -er "$q" "$f"
}

json_pretty() {
  require_jq
  jq . "$1"
}
