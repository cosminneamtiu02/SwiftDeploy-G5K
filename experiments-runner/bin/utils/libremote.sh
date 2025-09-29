#!/usr/bin/env bash
# libremote.sh — ssh/scp wrappers with retries
set -Eeuo pipefail
IFS=$'\n\t'

SSH_RETRIES=${SSH_RETRIES:-3}
SSH_OPTS_BASE=(
	-o "BatchMode=yes"
	-o "StrictHostKeyChecking=accept-new"
	-o "PreferredAuthentications=publickey"
	-o "PasswordAuthentication=no"
	-o "KbdInteractiveAuthentication=no"
)

ssh_retry() {
	# usage: ssh_retry user host key "command..."
	local user="$1" host="$2" key="$3" cmd="$4"
	local attempt=1
	while ((attempt <= SSH_RETRIES)); do
		if ssh "${SSH_OPTS_BASE[@]}" -i "${key}" "${user}@${host}" "${cmd}"; then
			return 0
		fi
		echo "[WARN] ssh attempt ${attempt} failed to ${user}@${host}; retrying..." >&2
		sleep $((attempt))
		((attempt++))
	done
	echo "[ERROR] ssh failed after ${SSH_RETRIES} attempts to ${user}@${host}" >&2
	return 1
}

scp_to_retry() {
	# usage: scp_to_retry user host key <src1> [src2 ...] <remote_path>
	local user="$1" host="$2" key="$3"
	shift 3
	local attempt=1
	local args=("$@")
	local remote_path="${args[-1]}"
	unset 'args[${#args[@]}-1]'
	while ((attempt <= SSH_RETRIES)); do
		if scp "${SSH_OPTS_BASE[@]}" -i "${key}" -r "${args[@]}" "${user}@${host}:${remote_path}"; then
			return 0
		fi
		echo "[WARN] scp(to) attempt ${attempt} failed to ${user}@${host}; retrying..." >&2
		sleep $((attempt))
		((attempt++))
	done
	echo "[ERROR] scp(to) failed after ${SSH_RETRIES} attempts to ${user}@${host}" >&2
	return 1
}

scp_from_retry() {
	# usage: scp_from_retry user host key <remote_path> <local_path>
	local user="$1" host="$2" key="$3" remote_path="$4" local_path="$5"
	local attempt=1
	while ((attempt <= SSH_RETRIES)); do
		if scp "${SSH_OPTS_BASE[@]}" -i "${key}" -r "${user}@${host}:${remote_path}" "${local_path}"; then
			return 0
		fi
		echo "[WARN] scp(from) attempt ${attempt} failed from ${user}@${host}; retrying..." >&2
		sleep $((attempt))
		((attempt++))
	done
	echo "[ERROR] scp(from) failed after ${SSH_RETRIES} attempts from ${user}@${host}" >&2
	return 1
}
