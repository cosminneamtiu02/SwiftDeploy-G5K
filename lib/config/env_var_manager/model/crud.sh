#!/usr/bin/env bash
# lib/config/env_crud/crud.sh - file-backed CRUD API for .env
# Public: eh_create, eh_read, eh_update, eh_delete

set -euo pipefail
_here_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_EH_env_file=$(realpath -m "${_here_dir}/../../../../.env")

_validate_key() {
    local k="$1"
    [[ -n "$k" && "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# Escape replacement for sed (escape backslashes, ampersand and slash)
_sed_escape_repl() {
    printf '%s' "$1" | sed -e 's/[\\&\/]/\\&/g'
}

# Read a key from disk. Prints value (raw) and returns 0; returns 1 if not found.
eh_read() {
    local key=${1:-}
    local val
    if [[ -z "$key" ]]; then
        echo "usage: eh_read KEY" >&2
        return 2
    fi
    if ! _validate_key "$key"; then
        echo "invalid key: $key" >&2
        return 2
    fi
    [[ -f "${_EH_env_file}" ]] || return 1
    val=$(awk -F= -v k="$key" 'BEGIN{OFS=FS} $1==k{ $1=""; sub(/^=/,""); print; exit }' "${_EH_env_file}")
    if [[ -n "$val" ]]; then
        printf '%s' "$val"
        return 0
    fi
    return 1
}

# Create a key (fail if exists)
eh_create() {
    local key=${1:-}
    local val=${2:-}
    if [[ -z "$key" ]]; then
        echo "usage: eh_create KEY VALUE" >&2
        return 2
    fi
    if ! _validate_key "$key"; then
        echo "invalid key: $key" >&2
        return 2
    fi
    # check existence
    if [[ -f "${_EH_env_file}" ]] && grep -q -E "^${key}=" "${_EH_env_file}"; then
        echo "key $key already exists" >&2
        return 3
    fi
    mkdir -p "$(dirname "${_EH_env_file}")" >/dev/null 2>&1 || true
    # append raw value
    printf '%s=%s\n' "$key" "$val" >> "${_EH_env_file}"
}

# Update existing key (fail if not present)
eh_update() {
    local key=${1:-}
    local val=${2:-}
    local esc
    if [[ -z "$key" ]]; then
        echo "usage: eh_update KEY VALUE" >&2
        return 2
    fi
    if ! _validate_key "$key"; then
        echo "invalid key: $key" >&2
        return 2
    fi
    if [[ ! -f "${_EH_env_file}" ]] || ! grep -q -E "^${key}=" "${_EH_env_file}"; then
        echo "key $key does not exist" >&2
        return 3
    fi
    esc=$(_sed_escape_repl "$val")
    sed -i "s/^${key}=.*/${key}=${esc}/" "${_EH_env_file}"
}

# Delete a key. Returns 0 if deleted, 1 if not found.
eh_delete() {
    local key=${1:-}
    if [[ -z "$key" ]]; then
        echo "usage: eh_delete KEY" >&2
        return 2
    fi
    if ! _validate_key "$key"; then
        echo "invalid key: $key" >&2
        return 2
    fi
    if [[ ! -f "${_EH_env_file}" ]] || ! grep -q -E "^${key}=" "${_EH_env_file}"; then
        return 1
    fi
    sed -i "/^${key}=/d" "${_EH_env_file}"
    return 0
}

# Prevent executing as script
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "This is a library; source it." >&2
    exit 2
fi
