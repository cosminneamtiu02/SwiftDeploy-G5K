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
	deploy_target_args=()
	if [[ -n ${G5K_HOST:-} ]]; then
		deploy_target_args=(-m "${G5K_HOST}")
	elif [[ -n ${OAR_NODEFILE:-} && -f ${OAR_NODEFILE} ]]; then
		deploy_target_args=(-f "${OAR_NODEFILE}")
	else
		echo "[ERROR] Neither G5K_HOST nor OAR_NODEFILE available to run kadeploy3." >&2
		exit 2
	fi

	# Retry wrapper for kadeploy3 to handle transient API timeouts
	KADE_RETRIES=${KADE_RETRIES:-3}
	KADE_BACKOFF_BASE=${KADE_BACKOFF_BASE:-5}
	attempt=1
	while :; do
		set +e
		kadeploy3 "${deploy_target_args[@]}" -a "${IMAGE_YAML_PATH}"
		rc=$?
		set -e
		if [[ ${rc} -eq 0 ]]; then
			break
		fi
		if ((attempt >= KADE_RETRIES)); then
			echo "[ERROR] kadeploy3 failed after ${attempt} attempt(s) (last rc=${rc})." >&2
			exit "${rc}"
		fi
		sleep_secs=$((KADE_BACKOFF_BASE * attempt))
		echo "[WARN] kadeploy3 failed (rc=${rc}). Retrying in ${sleep_secs}s... (${attempt}/${KADE_RETRIES})" >&2
		sleep "${sleep_secs}"
		attempt=$((attempt + 1))
	done
else
	echo "[ERROR] kadeploy3 command not found on FE." >&2
	exit 2
fi

echo "[INFO] Waiting for node to reboot into deployed OS and open SSH (port 22)..."
WAIT_READY_TIMEOUT=${WAIT_READY_TIMEOUT:-600}
WAIT_READY_INTERVAL=${WAIT_READY_INTERVAL:-5}
deadline=$(($(date +%s) + WAIT_READY_TIMEOUT))
while :; do
	now=$(date +%s)
	if ((now >= deadline)); then
		echo "[ERROR] Timeout waiting for SSH port to open after kadeploy." >&2
		# Don't exit immediately; proceed and let downstream steps attempt connections with richer logs
		break
	fi
	if command -v nc >/dev/null 2>&1; then
		if nc -z -w 3 "${G5K_HOST}" 22 2>/dev/null; then
			echo "[INFO] SSH port 22 is open on ${G5K_HOST}."
			break
		fi
	else
		# Fallback to bash /dev/tcp probe
		if timeout 3 bash -c ">/dev/tcp/${G5K_HOST}/22" 2>/dev/null; then
			echo "[INFO] SSH port 22 is open on ${G5K_HOST}."
			break
		fi
	fi
	sleep "${WAIT_READY_INTERVAL}"
done

echo "[INFO] Checking connectivity to ${G5K_USER}@${G5K_HOST} (best-effort) ..."
# Prefer oarsh when running inside an OAR job (partial allocations may block plain ssh).
if command -v oarsh >/dev/null 2>&1 && [[ -n ${OAR_NODEFILE:-} || -n ${OAR_JOB_ID:-} ]]; then
	if [[ -n ${OAR_JOB_ID:-} ]]; then
		# Try oarsh with job tunnel first
		if timeout 10 oarsh -t "${OAR_JOB_ID}" "${G5K_HOST}" true; then
			echo "[INFO] Connectivity OK via: oarsh -t ${OAR_JOB_ID} ${G5K_HOST}"
		else
			echo "[WARN] oarsh -t ${OAR_JOB_ID} failed to reach ${G5K_HOST}. Trying plain oarsh..." >&2
			if timeout 10 oarsh "${G5K_HOST}" true; then
				echo "[INFO] Connectivity OK via: oarsh ${G5K_HOST}"
			else
				echo "[WARN] plain oarsh failed. Falling back to direct ssh..." >&2
				if ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" true; then
					echo "[INFO] Connectivity OK via: ssh ${G5K_USER}@${G5K_HOST}"
				else
					echo "[WARN] Unable to connect to ${G5K_HOST} via oarsh (with/without -t) or ssh right now." >&2
					echo "      Downstream steps will retry using oarsh/oarcp." >&2
					# Run diagnostics to help debugging connectivity, write into LOG_DIR if set
					SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
					ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
					bash "${ROOT_DIR}/bin/utils/diagnostics-g5k-connectivity.sh" || true
				fi
			fi
		fi
	else
		# Inside an OAR context without explicit job id; try plain oarsh then ssh
		if timeout 10 oarsh "${G5K_HOST}" true; then
			echo "[INFO] Connectivity OK via: oarsh ${G5K_HOST}"
		else
			echo "[WARN] plain oarsh failed. Falling back to direct ssh..." >&2
			if ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" true; then
				echo "[INFO] Connectivity OK via: ssh ${G5K_USER}@${G5K_HOST}"
			else
				echo "[WARN] Unable to connect to ${G5K_HOST} via oarsh or ssh right now. Continuing..." >&2
				SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
				ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
				bash "${ROOT_DIR}/bin/utils/diagnostics-g5k-connectivity.sh" || true
			fi
		fi
	fi
else
	# No oarsh context; try direct ssh
	if ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "${G5K_SSH_KEY}" "${G5K_USER}@${G5K_HOST}" true; then
		echo "[INFO] Connectivity OK via: ssh ${G5K_USER}@${G5K_HOST}"
	else
		echo "[WARN] Unable to SSH to ${G5K_USER}@${G5K_HOST}. Continuing..." >&2
		SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
		bash "${ROOT_DIR}/bin/utils/diagnostics-g5k-connectivity.sh" || true
	fi
fi

echo "[INFO] Manual machine instantiation completed (deploy done; connectivity probes attempted)."
