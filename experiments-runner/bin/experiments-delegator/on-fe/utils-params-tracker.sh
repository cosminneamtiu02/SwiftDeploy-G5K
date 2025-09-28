#!/usr/bin/env bash
# utils-params-tracker.sh — Manage tracker file; select next lines and append.

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} ${BASH_COMMAND}" >&2' ERR

usage() {
	cat <<EOF
Usage:
  ${0##*/} select_next_lines <params_file> <tracker_file> <max_count>
  ${0##*/} append_tracker <tracker_file> <line1> [line2 ...]
EOF
}

dedupe_file() {
	# Remove blank and comment lines; normalize whitespace
	awk 'BEGIN{RS="\n"} {gsub(/^\s+|\s+$/,"",$0)} $0!~/^(#|$)/{print $0}' "$1"
}

select_next_lines() {
	local params_file="$1" tracker_file="$2" max_count="$3"
	[[ -f ${params_file} ]] || {
		echo "[ERROR] params file not found: ${params_file}" >&2
		exit 2
	}
	[[ -n ${max_count} ]] || {
		echo "[ERROR] max_count required" >&2
		exit 2
	}

	local tmp_params tmp_tracker
	tmp_params="$(mktemp)"
	tmp_tracker="$(mktemp)"
	dedupe_file "${params_file}" >"${tmp_params}"
	if [[ -f ${tracker_file} ]]; then dedupe_file "${tracker_file}" >"${tmp_tracker}"; else : >"${tmp_tracker}"; fi

	# TODO lines = params minus tracker (exact match)
	if command -v grep >/dev/null 2>&1; then
		# Use grep -F -x -v for speed; handle empty tracker gracefully
		if [[ -s ${tmp_tracker} ]]; then
			grep -F -x -v -f "${tmp_tracker}" "${tmp_params}" | head -n "${max_count}"
		else
			head -n "${max_count}" "${tmp_params}"
		fi
	else
		# POSIX awk fallback
		awk 'NR==FNR{seen[$0]=1; next} !seen[$0]++' "${tmp_tracker}" "${tmp_params}" | head -n "${max_count}"
	fi
	rm -f "${tmp_params}" "${tmp_tracker}"
}

append_tracker() {
	local tracker_file="$1"
	shift
	[[ -n ${tracker_file} ]] || {
		echo "[ERROR] tracker_file required" >&2
		exit 2
	}
	[[ $# -gt 0 ]] || {
		echo "[ERROR] at least one line to append required" >&2
		exit 2
	}

	# Try to use flock for simple atomic append
	if command -v flock >/dev/null 2>&1; then
		exec 9>>"${tracker_file}"
		flock 9
		for line in "$@"; do
			printf '%s\n' "${line}" >&9
		done
		flock -u 9
		exec 9>&-
	else
		for line in "$@"; do
			printf '%s\n' "${line}" >>"${tracker_file}"
		done
	fi
}

case "$1" in
	select_next_lines)
		shift
		select_next_lines "$@"
		;;
	append_tracker)
		shift
		append_tracker "$@"
		;;
	-h | --help | *)
		usage
		[[ $1 == "-h" || $1 == "--help" ]] || exit 2
		;;
esac
