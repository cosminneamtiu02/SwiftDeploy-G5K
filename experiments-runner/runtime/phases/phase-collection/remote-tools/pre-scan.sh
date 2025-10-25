#!/usr/bin/env bash
set +u
set -o pipefail
IFS=$'\n\t'

shopt -s nullglob

dir="${LOOK_INTO_REMOTE:-}"
if [[ -z ${dir} ]]; then
	echo "PRE:missing=1"
	exit 0
fi

patterns_raw="${PATTERNS_GLOBS:-}"

if ! host_value=$(hostname 2>/dev/null); then
	host_value="unknown"
fi
echo "PRE:host=${host_value}"
echo "PRE:dir_var=${dir}"
if stat_output=$(stat --format='%A %h %U %G %s %y %n' -- "${dir}" 2>/dev/null); then
	printf 'PRE:dir_stat: %s\n' "${stat_output}"
else
	echo "PRE:dir_stat:ls_failed"
fi
cd "${dir}" 2>/dev/null || {
	echo "PRE:missing=1"
	exit 0
}

echo "PRE:pwd=${PWD}"
entries_total=0
regular_total=0
entries_list=()
scan_tmp=$(mktemp) || scan_tmp=""
if [[ -n ${scan_tmp} ]] && find . -maxdepth 1 -mindepth 1 -print0 2>/dev/null >"${scan_tmp}"; then
	while IFS= read -r -d '' entry_path; do
		entries_total=$((entries_total + 1))
		trimmed="${entry_path#./}"
		entries_list+=("${trimmed}")
		[[ -f ${trimmed} ]] && regular_total=$((regular_total + 1))
	done <"${scan_tmp}"
fi
if [[ -n ${scan_tmp} ]]; then
	rm -f "${scan_tmp}"
fi
echo "PRE:entries_total=${entries_total}"
echo "PRE:regular_total=${regular_total}"
for entry_trimmed in "${entries_list[@]}"; do
	printf 'PRE:list:%s\n' "${entry_trimmed}"
done

for pattern in ${patterns_raw% }; do
	echo "PREPAT:pattern:${pattern}"
	matches=()
	for remote_file in ${pattern}; do
		[[ -f ${remote_file} ]] || continue
		matches+=("${remote_file}")
	done
	if ((${#matches[@]} == 0)); then
		echo "PREPAT:nomatch:\"${pattern}\""
	fi
	for remote_file in "${matches[@]}"; do
		printf 'PREPAT:match:"%s":"%s"\n' "${pattern}" "${remote_file}"
	done
	printf 'PREPAT:count:"%s":%d\n' "${pattern}" "${#matches[@]}"
done
