#!/usr/bin/env bash
set +u
set -o pipefail
IFS=$'\n\t'

shopt -s nullglob

remote_dir="${LOOK_INTO_REMOTE:-}"
if [[ -z ${remote_dir} ]]; then
	echo "DIAG:missing=1"
	exit 0
fi

patterns_raw="${PATTERNS_GLOBS:-}"

if ! host_value=$(hostname 2>/dev/null); then
	host_value="unknown"
fi
echo "DIAG:host=${host_value}"
echo "DIAG:dir_var=${remote_dir}"
if stat_output=$(stat --format='%A %h %U %G %s %y %n' -- "${remote_dir}" 2>/dev/null); then
	printf 'DIAG:dir_stat: %s\n' "${stat_output}"
else
	echo "DIAG:dir_stat:ls_failed"
fi
cd "${remote_dir}" 2>/dev/null || {
	echo "DIAG:missing=1"
	exit 0
}

echo "DIAG:pwd=${PWD}"
if ! whoami_value=$(whoami 2>/dev/null); then
	whoami_value="unknown"
fi
echo "DIAG:whoami=${whoami_value}"
echo "DIAG:shellopts=$-"
echo "DIAG:patterns_raw=${patterns_raw% }"

entries_count=0
entries_tmp=$(mktemp) || entries_tmp=""
if [[ -n ${entries_tmp} ]] && find . -mindepth 1 -maxdepth 1 -print0 2>/dev/null >"${entries_tmp}"; then
	while IFS= read -r -d '' _; do
		entries_count=$((entries_count + 1))
	done <"${entries_tmp}"
fi
if [[ -n ${entries_tmp} ]]; then
	rm -f "${entries_tmp}"
fi
echo "DIAG:entries_count=${entries_count}"

echo "DIAG:all_files_begin"
for remote_file in *; do
	[[ -f ${remote_file} ]] || continue
	size_bytes=$(wc -c <"${remote_file}" 2>/dev/null || echo 0)
	mtime_epoch=$(stat -c %Y "${remote_file}" 2>/dev/null || echo 0)
	echo "DIAG:file_meta:\"${remote_file}\":size=\"${size_bytes}\":mtime_epoch=\"${mtime_epoch}\""

done
echo "DIAG:all_files_end"

plain_count=0
for remote_file in *; do
	[[ -f ${remote_file} ]] && plain_count=$((plain_count + 1))
done
echo "DIAG:plain_file_count=${plain_count}"

echo "DIAG:first_entries_start"
ls_tmp=$(mktemp) || ls_tmp=""
if [[ -n ${ls_tmp} ]] && ls -la 2>/dev/null >"${ls_tmp}"; then
	mapfile -t ls_entries <"${ls_tmp}"
	for idx in "${!ls_entries[@]}"; do
		if ((idx >= 50)); then
			break
		fi
		printf 'DIAG:ls:%s\n' "${ls_entries[idx]}"
	done
else
	ls_entries=()
fi
if [[ -n ${ls_tmp} ]]; then
	rm -f "${ls_tmp}"
fi
echo "DIAG:first_entries_end"

for pattern in ${patterns_raw% }; do
	case "${pattern}" in
		*[*?[]*) echo "DIAG:pattern_header:\"${pattern}\":glob=\"yes\"" ;;
		*) echo "DIAG:pattern_header:\"${pattern}\":glob=\"no\"" ;;
	esac
	match_count=0
	for remote_file in $(compgen -G "${pattern}" 2>/dev/null); do
		[[ -f ${remote_file} ]] || continue
		size_bytes=$(wc -c <"${remote_file}" 2>/dev/null || echo 0)
		mtime_epoch=$(stat -c %Y "${remote_file}" 2>/dev/null || echo 0)
		echo "DIAG:match:\"${pattern}\":\"${remote_file}\":size=\"${size_bytes}\":mtime_epoch=\"${mtime_epoch}\""
		match_count=$((match_count + 1))
	done
	if ((match_count == 0)); then
		echo "DIAG:pattern_no_matches:\"${pattern}\""
	fi
	echo "DIAG:pattern_count:\"${pattern}\":count=\"${match_count}\""

done

shopt -p nullglob
echo "DIAG:env_HOME=${HOME}"
echo "DIAG:env_USER=${USER}"
