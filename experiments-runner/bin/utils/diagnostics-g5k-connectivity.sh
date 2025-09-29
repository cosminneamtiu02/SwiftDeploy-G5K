#!/usr/bin/env bash
# diagnostics-g5k-connectivity.sh — Collect verbose connectivity diagnostics on G5K

set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO ${BASH_COMMAND}" >&2' ERR

OUT_FILE="${LOG_DIR:-./}/diagnostics-$(date +%Y%m%d-%H%M%S).txt"
HOST="${G5K_HOST:-}"
JID="${OAR_JOB_ID:-}"

{
	echo "=== G5K connectivity diagnostics ==="
	ts_now=$(date -Is || true)
	echo "ts: ${ts_now}"
	echo "user: ${USER:-?}"
	echo "host: ${HOST:-<unset>}"
	echo "job: ${JID:-<unset>}"
	echo "nodefile: ${OAR_NODEFILE:-<unset>}"
	echo

	echo "--- oarstat (user jobs) ---"
	command -v oarstat >/dev/null 2>&1 && oarstat -u || echo "oarstat not available"
	echo

	if [[ -n ${JID:-} ]]; then
		echo "--- oarstat -j ${JID} -f (selected fields) ---"
		oarstat -j "${JID}" -f | grep -Ei 'state|assigned_hostnames|queue|job_type|initial_request|reservation' || true
		echo
	fi

	echo "--- resolve host ---"
	getent hosts "${HOST}" || true
	echo

	echo "--- check ssh port 22 ---"
	if command -v nc >/dev/null 2>&1; then
		nc -vz -w 3 "${HOST}" 22 || true
	else
		timeout 3 bash -lc ">/dev/tcp/${HOST}/22" && echo "tcp/22: open" || echo "tcp/22: closed"
	fi
	echo

	echo "--- oarsh -t test (10s timeout) ---"
	if command -v oarsh >/dev/null 2>&1 && [[ -n ${JID:-} ]]; then
		(
			set -x
			timeout 10 oarsh -t "${JID}" "${HOST}" 'echo OK_oarsh_tunnel && hostname && id'
		) || echo "oarsh -t failed"
	else
		echo "oarsh or job id not available"
	fi
	echo

	echo "--- plain oarsh test (10s timeout) ---"
	if command -v oarsh >/dev/null 2>&1; then
		(
			set -x
			timeout 10 oarsh "${HOST}" 'echo OK_plain_oarsh && hostname && id'
		) || echo "plain oarsh failed"
	else
		echo "oarsh not available"
	fi
	echo

	echo "--- ssh -vvv banner/auth test (10s) ---"
	(
		set -x
		ssh -vvv -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${G5K_USER:-${USER}}@${HOST}" 'echo OK_ssh && hostname && id'
	) || echo "ssh failed"
	echo

	echo "--- cpuset hint via oarsh (if possible) ---"
	if command -v oarsh >/dev/null 2>&1 && [[ -n ${JID:-} ]]; then
		(
			set -x
			timeout 10 oarsh -t "${JID}" "${HOST}" 'ls -ld /sys/fs/cgroup/cpuset || ls -ld /dev/cpuset || mount | grep -Ei "cgroup|cpuset" || true'
		) || true
	fi
	echo

	echo "--- environment summary ---"
	echo "G5K_USER=${G5K_USER:-}"
	echo "G5K_HOST=${G5K_HOST:-}"
	ssh_key_exists=no
	if [[ -n ${G5K_SSH_KEY:-} ]] && [[ -f ${G5K_SSH_KEY} ]]; then
		ssh_key_exists=yes
	fi
	echo "G5K_SSH_KEY=${G5K_SSH_KEY:-} (exists: ${ssh_key_exists})"
	image_yaml_exists=no
	if [[ -n ${IMAGE_YAML_PATH:-} ]] && [[ -f ${IMAGE_YAML_PATH} ]]; then
		image_yaml_exists=yes
	fi
	echo "IMAGE_YAML_PATH=${IMAGE_YAML_PATH:-} (exists: ${image_yaml_exists})"
} | tee "${OUT_FILE}" >/dev/null

echo "[INFO] Diagnostics written to ${OUT_FILE}"
