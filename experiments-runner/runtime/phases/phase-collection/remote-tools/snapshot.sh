#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

shopt -s nullglob

remote_dir="${DIR_REMOTE:-}"
if [[ ! -d ${remote_dir} ]]; then
	exit 4
fi
cd "${remote_dir}" || exit 4

IFS=' ' read -r -a patterns <<<"${PATTERNS_GLOBS:-}" || true
IFS=$'\n\t'

declare -A seen=()
files=()
for pattern in "${patterns[@]}"; do
	for remote_file in ${pattern}; do
		[[ -f ${remote_file} ]] || continue
		if [[ -z ${seen[${remote_file}]+x} ]]; then
			seen["${remote_file}"]=1
			files+=("${remote_file}")
		fi
	done
done

((${#files[@]} == 0)) && exit 7

tar -czf - --no-recursion -- "${files[@]}"
