#!/usr/bin/env bash
# install.sh - minimal installer for project
# For now: ensure a .env file exists at the project root

set -euo pipefail
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_env_file="${_script_dir}/.env"

if [[ -f "${_env_file}" ]]; then
    echo ".env already exists at ${_env_file}"
    exit 0
fi

printf "# .env (created by install.sh)\n" > "${_env_file}"
chmod 600 "${_env_file}" || true
echo "Created .env at ${_env_file}"
