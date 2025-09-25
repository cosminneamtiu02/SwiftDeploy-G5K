#!/usr/bin/env bash
# write-env.sh — Persist env vars to /etc/profile.d or ~/.profile

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO ${BASH_COMMAND}" >&2' ERR

DRY_RUN=false
JSON_FILE=""

usage() {
  cat <<EOF
Usage: write-env.sh --json-file <config.json> [--dry-run]
Reads machine_setup.env_variables_list and persists them.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json-file) JSON_FILE="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2;;
  esac
done

[[ -f "$JSON_FILE" ]] || { echo "[ERROR] JSON file not found: $JSON_FILE" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq required" >&2; exit 2; }

ENV_LIST_JSON="$(jq -c '.machine_setup.env_variables_list // []' "$JSON_FILE")"

target_file=""
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  target_file="/etc/profile.d/99-experiments.sh"
else
  target_file="$HOME/.profile"
fi

echo "[INFO] Persisting env vars to $target_file"

append_line() {
  local line="$1"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] append: $line -> $target_file"
  else
    if [[ "$target_file" == /etc/profile.d/* ]]; then
      printf '%s\n' "$line" | sudo tee -a "$target_file" >/dev/null
    else
      printf '%s\n' "$line" >> "$target_file"
    fi
  fi
}

# Ensure shebang/comment header for /etc/profile.d script
if [[ "$target_file" == /etc/profile.d/* && "$DRY_RUN" == false ]]; then
  if [[ ! -f "$target_file" ]]; then
    sudo bash -lc "echo '# Experiments env vars' > '$target_file'"
    sudo chmod 0644 "$target_file"
  fi
fi

# Iterate list of single-pair objects
len=$(jq 'length' <<<"$ENV_LIST_JSON")
for ((i=0; i<len; i++)); do
  kv_json=$(jq -c ".[$i]" <<<"$ENV_LIST_JSON")
  key=$(jq -r 'keys[0]' <<<"$kv_json")
  val=$(jq -r '.[]' <<<"$kv_json")
  line="export ${key}=${val}"
  append_line "$line"
  echo "[INFO] Set ${key} in ${target_file}"
done

echo "[INFO] Env write complete. Reload your shell or source the profile to apply."
