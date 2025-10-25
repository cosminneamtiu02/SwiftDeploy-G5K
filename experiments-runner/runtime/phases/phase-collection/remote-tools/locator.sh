#!/usr/bin/env bash
set +u
set -o pipefail
IFS=$'\n\t'

shopt -s nullglob

alt_dirs="${ALT_DIRS:-}"
patterns_raw="${PATTERNS_GLOBS:-}"

for candidate_dir in ${alt_dirs}; do
	if [[ -d ${candidate_dir} ]]; then
		dir_entries=()
		find_tmp=$(mktemp) || find_tmp=""
		if [[ -n ${find_tmp} ]] && find "${candidate_dir}" -maxdepth 1 -mindepth 1 -printf '%P\0' 2>/dev/null >"${find_tmp}"; then
			while IFS= read -r -d '' entry; do
				dir_entries+=("${entry}")
			done <"${find_tmp}"
		fi
		if [[ -n ${find_tmp} ]]; then
			rm -f "${find_tmp}"
		fi
		entries=${#dir_entries[@]}
		plain=0
		for entry in "${dir_entries[@]}"; do
			[[ -f "${candidate_dir}/${entry}" ]] && plain=$((plain + 1))
		done
		echo "LOC:dir:${candidate_dir}:entries=${entries}:plain=${plain}"
		(
			cd "${candidate_dir}" 2>/dev/null || exit 0
			for pattern in ${patterns_raw% }; do
				count=0
				for match in ${pattern}; do
					[[ -f ${match} ]] || continue
					count=$((count + 1))
				done
				echo "LOC:pattern_count_dir:${candidate_dir}:${pattern}:count=${count}"
			done
			echo "LOC:first_files_dir:${candidate_dir}"
			listing=()
			listing_tmp=$(mktemp) || listing_tmp=""
			if [[ -n ${listing_tmp} ]] && ls -1 2>/dev/null >"${listing_tmp}"; then
				mapfile -t listing <"${listing_tmp}"
			fi
			if [[ -n ${listing_tmp} ]]; then
				rm -f "${listing_tmp}"
			fi
			for idx in "${!listing[@]}"; do
				if ((idx >= 10)); then
					break
				fi
				printf 'LOC:file:"%s":"%s"\n' "${candidate_dir}" "${listing[idx]}"
			done
		)
	else
		echo "LOC:dir_missing:${candidate_dir}"
	fi
done

if [[ -d ${EXEC_DIR_REMOTE:-} ]]; then
	for pattern in ${patterns_raw% }; do
		echo "LOC:search_under:${EXEC_DIR_REMOTE}:pattern:${pattern}"
		found_lines=()
		find_remote_tmp=$(mktemp) || find_remote_tmp=""
		if [[ -n ${find_remote_tmp} ]] && find "${EXEC_DIR_REMOTE}" -maxdepth 3 -type f -name "${pattern}" -printf '%T@ %p\n' 2>/dev/null >"${find_remote_tmp}"; then
			mapfile -t found_lines <"${find_remote_tmp}"
		fi
		if [[ -n ${find_remote_tmp} ]]; then
			rm -f "${find_remote_tmp}"
		fi
		if ((${#found_lines[@]} > 0)); then
			tmp_file=$(mktemp) || tmp_file=""
			sorted_found=()
			sorted_tmp=""
			if [[ -n ${tmp_file} ]]; then
				printf '%s\n' "${found_lines[@]}" >"${tmp_file}"
				sorted_tmp=$(mktemp) || sorted_tmp=""
				if [[ -n ${sorted_tmp} ]] && sort -nr "${tmp_file}" >"${sorted_tmp}"; then
					mapfile -t sorted_found <"${sorted_tmp}"
				else
					sorted_found=("${found_lines[@]}")
				fi
				if [[ -n ${sorted_tmp} ]]; then
					rm -f "${sorted_tmp}"
				fi
				rm -f "${tmp_file}"
			else
				sorted_found=("${found_lines[@]}")
			fi
			for idx in "${!sorted_found[@]}"; do
				if ((idx >= 10)); then
					break
				fi
				entry_line="${sorted_found[idx]}"
				path_part="${entry_line#* }"
				printf 'LOC:found: %s\n' "${path_part}"
			done
		fi
	done
fi
