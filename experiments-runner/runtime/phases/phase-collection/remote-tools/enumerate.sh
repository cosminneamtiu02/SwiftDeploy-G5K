#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

shopt -s nullglob

remote_dir="${DIR_REMOTE:-}"
if [[ ! -d ${remote_dir} ]]; then
	exit 3
fi
cd "${remote_dir}" || exit 4

IFS=' ' read -r -a patterns <<<"${PATTERNS_GLOBS:-}" || true
IFS=$'\n\t'

declare -A seen=()
for pattern in "${patterns[@]}"; do
	for remote_file in ${pattern}; do
		[[ -f ${remote_file} ]] || continue
		if [[ -z ${seen[${remote_file}]+x} ]]; then
			printf '%s\n' "${remote_file}"
			seen["${remote_file}"]=1
		fi
	done
done
