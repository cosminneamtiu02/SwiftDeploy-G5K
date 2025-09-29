#!/usr/bin/env bash
# manual-machine-start.sh
# Purpose: Guide manual instantiation on Grid'5000 and verify SSH connectivity.
# Inputs: JSON config via controller; environment variables G5K_USER, G5K_HOST, G5K_SSH_KEY.
# Exit codes: 0 success, 1 invalid env, 2 connectivity failure.

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO ${BASH_COMMAND}" >&2' ERR

usage() {
	cat <<EOF
manual-machine-start.sh --help

This script prints instructions for manual Grid'5000 instantiation and validates SSH access.

Environment expected after manual steps:
	G5K_USER     Grid'5000 username
	G5K_HOST     Target SSH host (e.g., node-1.site.grid5000.fr)
	G5K_SSH_KEY  Path to private key for SSH

Validation performed:
	if [[ -z "${G5K_SSH_KEY:-}" ]]; then
		echo "G5K_SSH_KEY is not set" >&2
		exit 1
	fi
	if [[ -z "${G5K_USER:-}" ]]; then
		echo "G5K_USER is not set" >&2
		exit 1
	fi
	if [[ -z "${G5K_HOST:-}" ]]; then
		echo "G5K_HOST is not set" >&2
		exit 1
	fi
	ssh -o BatchMode=yes -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" true

Exit codes:
	0 OK
	1 Missing env
	2 SSH connectivity failure
EOF
}

if [[ ${1:-} == "--help" ]]; then
	usage
	exit 0
fi

echo "[INFO] Manual instantiation selected. Please perform the following on Grid'5000:"
echo "  1) On the FE, reserve nodes with oarsub and wait for allocation (this can be interactive or non-interactive)."
echo "  2) Deploy the requested image (see machine_setup.image_to_use)."
echo "  3) Export the environment variables so downstream scripts can reach the node (from the FE you can use oarsh/oarcp with -t ${OAR_JOB_ID}):"
echo "     export G5K_USER=your_user"
echo "     export G5K_HOST=node-1.site.grid5000.fr"
echo "     export G5K_SSH_KEY=~/.ssh/id_rsa"

echo "[INFO] Verifying environment variables..."

# Check required environment variables
for v in G5K_USER G5K_HOST G5K_SSH_KEY; do
	if [[ -z ${!v:-} ]]; then
		echo "[ERROR] Environment variable ${v} is required but not set." >&2
		exit 2
	fi
done

if [[ ! -f ${G5K_SSH_KEY} ]]; then
	echo "[ERROR] SSH key not found: ${G5K_SSH_KEY}" >&2
	exit 1
fi

echo "[INFO] Checking connectivity to ${G5K_USER}@${G5K_HOST} ..."
# Prefer oarsh when running inside an OAR job (partial allocations may block plain ssh).
if command -v oarsh >/dev/null 2>&1 && [[ -n ${OAR_NODEFILE:-} || -n ${OAR_JOB_ID:-} ]]; then
	if [[ -n ${OAR_JOB_ID:-} ]]; then
		if ! oarsh -t "${OAR_JOB_ID}" "${G5K_HOST}" true; then
			echo "[ERROR] Unable to connect with oarsh -t ${OAR_JOB_ID} to ${G5K_HOST}" >&2
			exit 2
		fi
	else
		if ! oarsh "${G5K_HOST}" true; then
			echo "[ERROR] Unable to connect with oarsh to ${G5K_HOST}" >&2
			exit 2
		fi
	fi
else
	if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" true; then
		echo "[ERROR] Unable to SSH to ${G5K_USER}@${G5K_HOST}" >&2
		echo "Hint: If the node isn't fully allocated, reserve a whole node (oarsub -I -l nodes=1,walltime=...) or use oarsh/oarcp."
		exit 2
	fi
fi

echo "[INFO] Manual machine instantiation verified."
