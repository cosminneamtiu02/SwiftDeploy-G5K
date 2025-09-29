#!/usr/bin/env bash
# install-dependencies.sh — OS-aware package installation using os_distribution_type.

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} ${BASH_COMMAND}" >&2' ERR

DRY_RUN=false
OS_TYPE=""
PKG_FILE=""

usage() {
	cat <<EOF
Usage: install-dependencies.sh --os-type {1|2|3} --packages-file <path> [--dry-run]
	1=Debian/apt, 2=RHEL7/yum, 3=RHEL7+/dnf.
EOF
}

while [[ $# -gt 0 ]]; do
	case "${1}" in
		--os-type)
			OS_TYPE="${2}"
			shift 2
			;;
		--packages-file)
			PKG_FILE="${2}"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "Unknown arg: ${1}" >&2
			usage
			exit 2
			;;
	esac
done

[[ -n ${OS_TYPE} ]] || {
	echo "[ERROR] --os-type required" >&2
	exit 2
}
[[ -f ${PKG_FILE} ]] || {
	echo "[ERROR] packages file not found: ${PKG_FILE}" >&2
	exit 2
}

mapfile_output=$(grep -vE '^[[:space:]]*(#|$)' "${PKG_FILE}")
IFS=$'\n' read -r -d '' -a PACKS <<<"${mapfile_output}" || true
if ((${#PACKS[@]} == 0)); then
	echo "[INFO] No packages to install (file empty or comments only)."
	exit 0
fi

run_cmd() {
	if [[ ${DRY_RUN} == true ]]; then
		echo "[DRY-RUN] $*"
	else
		# shellcheck disable=SC2048,SC2086
		"$@"
	fi
}

case "${OS_TYPE}" in
	1)
		echo "[INFO] Using apt for installation"
		run_cmd sudo apt-get update
		run_cmd sudo apt-get install -y "${PACKS[@]}"
		;;
	2)
		echo "[INFO] Using yum for installation (RHEL7)"
		run_cmd sudo yum makecache
		run_cmd sudo yum install -y "${PACKS[@]}"
		;;
	3)
		echo "[INFO] Using dnf for installation (RHEL7+)"
		run_cmd sudo dnf makecache
		run_cmd sudo dnf install -y "${PACKS[@]}"
		;;
	*)
		echo "[ERROR] Unknown --os-type: ${OS_TYPE}" >&2
		exit 2
		;;
esac

echo "[INFO] Installation commands issued for ${#PACKS[@]} packages."
