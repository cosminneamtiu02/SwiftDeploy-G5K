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

echo "[INFO] Manual instantiation selected. Running automatic deploy from the FE first."

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

# Require an image YAML to deploy
if [[ -z ${IMAGE_YAML_PATH:-} ]]; then
	echo "[ERROR] IMAGE_YAML_PATH is not set. Upstream controller should export it after resolving image_to_use." >&2
	exit 2
fi
if [[ ! -f ${IMAGE_YAML_PATH} ]]; then
	echo "[ERROR] Image YAML not found: ${IMAGE_YAML_PATH}" >&2
	exit 2
fi

echo "[INFO] Deploying image to ${G5K_HOST} using kadeploy3 (YAML: ${IMAGE_YAML_PATH})"
# Prefer host if provided; fallback to OAR_NODEFILE if available
if command -v kadeploy3 >/dev/null 2>&1; then
	if [[ -n ${G5K_HOST:-} ]]; then
		kadeploy3 -m "${G5K_HOST}" -a "${IMAGE_YAML_PATH}"
	elif [[ -n ${OAR_NODEFILE:-} && -f ${OAR_NODEFILE} ]]; then
		kadeploy3 -f "${OAR_NODEFILE}" -a "${IMAGE_YAML_PATH}"
	else
		echo "[ERROR] Neither G5K_HOST nor OAR_NODEFILE available to run kadeploy3." >&2
		exit 2
	fi
else
	echo "[ERROR] kadeploy3 command not found on FE." >&2
	exit 2
fi

echo "[INFO] Waiting for node to reboot into deployed OS and become reachable..."
WAIT_READY_TIMEOUT=${WAIT_READY_TIMEOUT:-420}
WAIT_READY_INTERVAL=${WAIT_READY_INTERVAL:-5}
deadline=$(($(date +%s) + WAIT_READY_TIMEOUT))
while :; do
	now=$(date +%s)
	if ((now >= deadline)); then
		echo "[ERROR] Timeout waiting for node to become reachable after kadeploy." >&2
		exit 2
	fi
	# Try oarsh -t if job id is known, otherwise plain oarsh, then ssh
	if command -v oarsh >/dev/null 2>&1 && [[ -n ${OAR_JOB_ID:-} ]]; then
		if oarsh -t "${OAR_JOB_ID}" "${G5K_HOST}" 'true' 2>/dev/null; then
			echo "[INFO] Node reachable via oarsh -t after deploy."
			break
		fi
	fi
	if command -v oarsh >/dev/null 2>&1; then
		if oarsh "${G5K_HOST}" 'true' 2>/dev/null; then
			echo "[INFO] Node reachable via oarsh after deploy."
			break
		fi
	fi
	if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" 'true' 2>/dev/null; then
		echo "[INFO] Node reachable via ssh after deploy."
		break
	fi
	sleep "${WAIT_READY_INTERVAL}"
done

echo "[INFO] Checking connectivity to ${G5K_USER}@${G5K_HOST} ..."
# Prefer oarsh when running inside an OAR job (partial allocations may block plain ssh).
if command -v oarsh >/dev/null 2>&1 && [[ -n ${OAR_NODEFILE:-} || -n ${OAR_JOB_ID:-} ]]; then
	if [[ -n ${OAR_JOB_ID:-} ]]; then
		# Try oarsh with job tunnel first
		if oarsh -t "${OAR_JOB_ID}" "${G5K_HOST}" true; then
			echo "[INFO] Connectivity OK via: oarsh -t ${OAR_JOB_ID} ${G5K_HOST}"
		else
			echo "[WARN] oarsh -t ${OAR_JOB_ID} failed to reach ${G5K_HOST}. Trying plain oarsh..." >&2
			if oarsh "${G5K_HOST}" true; then
				echo "[INFO] Connectivity OK via: oarsh ${G5K_HOST}"
			else
				echo "[WARN] plain oarsh failed. Falling back to direct ssh..." >&2
				if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" true; then
					echo "[INFO] Connectivity OK via: ssh ${G5K_USER}@${G5K_HOST}"
				else
					echo "[ERROR] Unable to connect to ${G5K_HOST} via oarsh (with/without -t) or ssh." >&2
					echo "Hint: Ensure your interactive job is active (oarsub -I -t deploy -q default) and the node is reachable from the FE." >&2
					exit 2
				fi
			fi
		fi
	else
		# Inside an OAR context without explicit job id; try plain oarsh then ssh
		if oarsh "${G5K_HOST}" true; then
			echo "[INFO] Connectivity OK via: oarsh ${G5K_HOST}"
		else
			echo "[WARN] plain oarsh failed. Falling back to direct ssh..." >&2
			if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" true; then
				echo "[INFO] Connectivity OK via: ssh ${G5K_USER}@${G5K_HOST}"
			else
				echo "[ERROR] Unable to connect to ${G5K_HOST} via oarsh or ssh." >&2
				exit 2
			fi
		fi
	fi
else
	# No oarsh context; try direct ssh
	if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" true; then
		echo "[INFO] Connectivity OK via: ssh ${G5K_USER}@${G5K_HOST}"
	else
		echo "[ERROR] Unable to SSH to ${G5K_USER}@${G5K_HOST}" >&2
		echo "Hint: If the node isn't fully allocated, keep the interactive job open: oarsub -I -t deploy -q default" >&2
		exit 2
	fi
fi

echo "[INFO] Manual machine instantiation verified."
