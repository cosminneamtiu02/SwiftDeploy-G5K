#!/usr/bin/env bash
# Orchestrates: machine instantiation -> project preparation -> delegate runs -> collect
# Usage: experiments-controller.sh --config <config_name.json> [--verbose]
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUNNER_ROOT="${REPO_ROOT}/experiments-runner"
BIN_DIR="${RUNNER_ROOT}/bin"
LOGS_DIR_BASE="${RUNNER_ROOT}/logs"
CONFIGS_DIR_PRIMARY="${RUNNER_ROOT}/experiments-configurations"
CONFIGS_DIR_IMPL="${CONFIGS_DIR_PRIMARY}/implementations"
CURRENT_NODE_FILE="${RUNNER_ROOT}/current_node.txt"
ALT_NODE_FILE="${REPO_ROOT}/current_node.txt"

# FE-side tracking (done.txt) variables
SELECTED_BATCH=""

# --- CLI args ---
CONFIG_NAME=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--config)
			CONFIG_NAME=${2:-}
			shift 2
			;;
		--verbose | -v)
			VERBOSE=true
			shift
			;;
		*)
			echo "Unknown argument: $1" >&2
			echo "Usage: $0 --config <config.json> [--verbose]" >&2
			exit 1
			;;
	esac
done

if [[ -z ${CONFIG_NAME} ]]; then
	echo "ERROR: --config <config.json> is required" >&2
	exit 1
fi

CONFIG_PATH=""
for base in "${CONFIGS_DIR_PRIMARY}" "${CONFIGS_DIR_IMPL}"; do
	if [[ -f "${base}/${CONFIG_NAME}" ]]; then
		CONFIG_PATH="${base}/${CONFIG_NAME}"
		break
	fi
done

if [[ -z ${CONFIG_PATH} ]]; then
	echo "ERROR: Config ${CONFIG_NAME} not found in: ${CONFIGS_DIR_PRIMARY} or ${CONFIGS_DIR_IMPL}" >&2
	exit 1
fi

# --- Logging ---
timestamp() { date +"%Y-%m-%d_%H-%M-%S"; }
LOG_DIR="${LOGS_DIR_BASE}/$(timestamp)"
mkdir -p "${LOG_DIR}"

# shellcheck source=/dev/null
LOG_FILE="${LOG_DIR}/controller.log"
export LOG_FILE
# shellcheck disable=SC1091
source "${RUNNER_ROOT}/bin/utils/liblog.sh"
log_info "Controller started. Logs: ${LOG_FILE}"

# Backward-compat: if plain 'log' isn't defined by the logging lib, map it to info
if ! declare -F log >/dev/null 2>&1; then
	log() { log_info "$@"; }
fi

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# --- Optional verbose mode (debug-level logs, no shell tracing noise) ---
if ${VERBOSE}; then
	export LOG_LEVEL=debug
fi

# --- Error trap for clearer failures ---
__on_err() {
	local exit_code=$?
	local line_no=${BASH_LINENO[0]:-?}
	local src_file=${BASH_SOURCE[1]:-$(basename "$0")}
	local last_cmd=${BASH_COMMAND:-unknown}
	log_error "Failure (exit=${exit_code}) at ${src_file}:${line_no} while running: ${last_cmd}"
	log_error "See ${LOG_FILE} for details."
}
trap __on_err ERR

# Ensure background streams are cleaned up on exit
__cleanup() {
	if [[ -n ${STREAM_PID:-} ]]; then
		kill "${STREAM_PID}" >/dev/null 2>&1 || true
		wait "${STREAM_PID}" >/dev/null 2>&1 || true
	fi
}
trap __cleanup EXIT

# --- Dependencies ---
require_cmd jq
require_cmd base64

# --- Read JSON helpers ---
jq_get() { jq -r "$1" "${CONFIG_PATH}"; }

IMAGE_YAML_NAME=$(jq_get '.machine_setup.image_to_use // empty')
IS_MANUAL=$(jq_get '.machine_setup.is_machine_instantiator_manual // true')
OS_DIST_TYPE=$(jq_get '.machine_setup.os_distribution_type // 1')

PAR_PATH=$(jq_get '.running_experiments.on_fe.to_do_parameters_list_path // empty')
EXEC_CMD=$(jq_get '.running_experiments.on_machine.execute_command // empty')
EXEC_DIR=$(jq_get '.running_experiments.on_machine.full_path_to_executable // empty')
PARALLEL_N=$(jq_get '.running_experiments.number_of_experiments_to_run_in_parallel_on_machine // 1')

# New collection schema fields
COLLECT_BASE_PATH=$(jq_get '.running_experiments.experiments_collection.base_path // empty')
COLLECT_LOOKUP_RULES_JSON=$(jq -c '.running_experiments.experiments_collection.lookup_rules // []' "${CONFIG_PATH}")
COLLECT_FTRANSFERS_JSON=$(jq -c '.running_experiments.experiments_collection.ftransfers // []' "${CONFIG_PATH}")

[[ -n ${IMAGE_YAML_NAME} ]] || die "Config error: .machine_setup.image_to_use is missing or empty"
[[ -n ${PAR_PATH} ]] || die "Config error: .running_experiments.on_fe.to_do_parameters_list_path is missing or empty"
[[ -n ${EXEC_CMD} ]] || die "Config error: .running_experiments.on_machine.execute_command is missing or empty"
[[ -n ${EXEC_DIR} ]] || die "Config error: .running_experiments.on_machine.full_path_to_executable is missing or empty"
[[ ${PARALLEL_N} =~ ^[0-9]+$ ]] || die "Config error: .running_experiments.number_of_experiments_to_run_in_parallel_on_machine must be an integer"

# --- Collection config validation ---
validate_collection_config() {
	# base_path optional (if omitted, skip collection entirely)
	if [[ -z ${COLLECT_BASE_PATH} ]]; then
		log_debug "No collection base_path defined; Phase 4 will be skipped."
		return 0
	fi
	if [[ ${COLLECT_BASE_PATH} =~ [/\\] ]]; then
		die "Invalid base_path '${COLLECT_BASE_PATH}': must be a simple folder name without slashes"
	fi
	# Validate lookup_rules: array of single-key objects
	local rules_count
	rules_count=$(jq 'length' <<<"${COLLECT_LOOKUP_RULES_JSON}")
	declare -A RULE_LABELS=()
	for ((i = 0; i < rules_count; i++)); do
		local entry entry_entries key_count label pattern
		entry=$(jq -c ".[${i}]" <<<"${COLLECT_LOOKUP_RULES_JSON}")
		# shellcheck disable=SC2312 # split into two commands to retain exit codes individually
		entry_entries=$(jq 'to_entries' <<<"${entry}")
		key_count=$(jq 'length' <<<"${entry_entries}")
		if [[ ${key_count} -ne 1 ]]; then
			die "lookup_rules entry index ${i} must have exactly one key"
		fi
		label=$(jq -r 'keys[0]' <<<"${entry}")
		pattern=$(jq -r '.[keys[0]]' <<<"${entry}")
		if [[ -z ${label} || -z ${pattern} ]]; then
			die "lookup_rules entry index ${i} has empty label or pattern"
		fi
		if [[ -n ${RULE_LABELS[${label}]:-} ]]; then
			die "Duplicate lookup rule label: ${label}"
		fi
		RULE_LABELS["${label}"]=1
	done
	# Validate ftransfers
	local transf_count
	transf_count=$(jq 'length' <<<"${COLLECT_FTRANSFERS_JSON}")
	for ((i = 0; i < transf_count; i++)); do
		local look_into subfolder
		look_into=$(jq -r ".[${i}].look_into // empty" <<<"${COLLECT_FTRANSFERS_JSON}")
		subfolder=$(jq -r ".[${i}].transfer_to_subfolder_of_base_path // empty" <<<"${COLLECT_FTRANSFERS_JSON}")
		[[ -n ${look_into} ]] || die "ftransfers[${i}].look_into missing"
		[[ ${look_into} == /* ]] || die "ftransfers[${i}].look_into must be an absolute path (got '${look_into}')"
		[[ -n ${subfolder} ]] || die "ftransfers[${i}].transfer_to_subfolder_of_base_path missing"
		if [[ ${subfolder} =~ [/\\] ]]; then
			die "ftransfers[${i}].transfer_to_subfolder_of_base_path must be simple folder (no slash): '${subfolder}'"
		fi
		# Validate look_for references
		mapfile -t lf_labels < <(jq -r ".[${i}].look_for[]?" <<<"${COLLECT_FTRANSFERS_JSON}" || true)
		if ((${#lf_labels[@]} == 0)); then
			die "ftransfers[${i}].look_for must list at least one rule label"
		fi
		for lbl in "${lf_labels[@]}"; do
			if [[ -z ${RULE_LABELS[${lbl}]:-} ]]; then
				die "ftransfers[${i}] references unknown rule label: ${lbl}"
			fi
		done
	done
	log_debug "Collection config validated: base_path='${COLLECT_BASE_PATH}', rules=${rules_count}, transfers=${transf_count}"
}

validate_collection_config

# --- Phase 0: FE-side selection using done.txt (before any machine work) ---
# Resolve params file on FE
resolve_params_file_fe() {
	local p="$1"
	if [[ -z ${p} ]]; then
		return 1
	fi
	if [[ ${p} == /* ]]; then
		printf '%s\n' "${p}"
	else
		printf '%s\n' "${RUNNER_ROOT}/params/${p}"
	fi
}

PAR_FILE_FE=$(resolve_params_file_fe "${PAR_PATH}")
[[ -f ${PAR_FILE_FE} ]] || die "Parameters list not found on FE: ${PAR_FILE_FE}"

# Determine done.txt path next to the params file
PAR_DIR_FE=$(dirname "${PAR_FILE_FE}")
DONE_FILE_FE="${PAR_DIR_FE}/done.txt"

# Read TODO lines (preserve order, ignore blanks)
mapfile -t FE_TODO_LINES < <(grep -v '^[[:space:]]*$' "${PAR_FILE_FE}" || true)

# Ensure done.txt exists (Case 1)
if [[ ! -f ${DONE_FILE_FE} ]]; then
	: >"${DONE_FILE_FE}"
fi
mapfile -t FE_DONE_LINES < <(grep -v '^[[:space:]]*$' "${DONE_FILE_FE}" || true)

# Build a quick membership map for done lines
declare -A FE_DONE_SET=()
for dl in "${FE_DONE_LINES[@]}"; do FE_DONE_SET["${dl}"]=1; done

# Select up to PARALLEL_N lines from TODO not in done.txt
FE_SELECTED_LINES=()
for tl in "${FE_TODO_LINES[@]}"; do
	if [[ -z ${FE_DONE_SET["${tl}"]+x} ]]; then
		FE_SELECTED_LINES+=("${tl}")
		if ((${#FE_SELECTED_LINES[@]} >= PARALLEL_N)); then
			break
		fi
	fi
done

if ((${#FE_SELECTED_LINES[@]} == 0)); then
	log_warn "Nothing left to run. Cleaning up done.txt and stopping."
	rm -f "${DONE_FILE_FE}" 2>/dev/null || true
	log_success "Stopped before execution: no pending parameters."
	exit 0
fi

# Display selected lines at the very beginning (before deploy)
log_step "Selected parameters for this run (n=${#FE_SELECTED_LINES[@]}):"
for sl in "${FE_SELECTED_LINES[@]}"; do
	ts=$(date +%H:%M:%S)
	echo "[${ts}] [INFO]  [FE] ${sl}"
done

# Snapshot done.txt BEFORE appending, so we can restore exact pre-run state on failure
BATCH_DONE_BACKUP="${DONE_FILE_FE}.bak.$(date +%s).$$"
cp -f "${DONE_FILE_FE}" "${BATCH_DONE_BACKUP}" 2>/dev/null || true

# Immediately append selected lines to done.txt
{
	for sl in "${FE_SELECTED_LINES[@]}"; do printf '%s\n' "${sl}"; done
} >>"${DONE_FILE_FE}"

# Prepare in-memory text and base64 for env export and for potential revert
SELECTED_BATCH_TEXT=$(printf '%s\n' "${FE_SELECTED_LINES[@]}")
export SELECTED_BATCH="${SELECTED_BATCH_TEXT}"
SELECTED_LINES_B64=$(printf '%s\n' "${FE_SELECTED_LINES[@]}" | base64 -w0)
FE_BATCH_OK=0

revert_done_batch() {
	# Prefer exact restore from snapshot if available
	if [[ -f ${BATCH_DONE_BACKUP} ]]; then
		mv -f "${BATCH_DONE_BACKUP}" "${DONE_FILE_FE}" 2>/dev/null || true
		log_info "Restored ${DONE_FILE_FE} from snapshot."
		return 0
	fi
	# Fallback: remove one occurrence of each selected line
	[[ -f ${DONE_FILE_FE} ]] || return 0
	local tmp tmp_sel
	tmp="${DONE_FILE_FE}.tmp.$$"
	tmp_sel=$(mktemp "${DONE_FILE_FE}.sel.XXXXXX")
	for __l in "${FE_SELECTED_LINES[@]}"; do printf '%s\n' "${__l}"; done >"${tmp_sel}"
	awk 'BEGIN{ while((getline line<ARGV[2])>0){c[line]++} close(ARGV[2]) } { if(c[$0]>0){ c[$0]--; next } print }' \
		"${DONE_FILE_FE}" "${tmp_sel}" >"${tmp}" || true
	mv "${tmp}" "${DONE_FILE_FE}" 2>/dev/null || true
	rm -f "${tmp_sel}" 2>/dev/null || true
}

# Arrange revert on any failure before successful completion
FE_BATCH_OK=0
__cleanup_fe_batch() {
	# Invoke after existing cleanup
	if [[ ${FE_BATCH_OK} -ne 1 ]]; then
		log_warn "Reverting FE done.txt entries for this batch due to failure/interruption."
		revert_done_batch
	else
		# Success: remove backup snapshot if present
		rm -f "${BATCH_DONE_BACKUP}" 2>/dev/null || true
	fi
}

# Chain cleanup: ensure our revert runs at EXIT, but only after controller-local cleanup
trap '__cleanup; __cleanup_fe_batch' EXIT

# Remove legacy duplicated FE selection logic below. The above block owns selection and revert.

# --- Phase 1: Machine instantiation (on FE) ---
log_step "Phase 1/4: Machine instantiation (${IS_MANUAL:+manual})"
INST_DIR="${BIN_DIR}/machine-instantiator/on-fe"
[[ -d ${INST_DIR} ]] || die "Missing directory: ${INST_DIR}"

if [[ ${IS_MANUAL} == "true" ]]; then
	"${INST_DIR}/manual_instantiator.sh" "${IMAGE_YAML_NAME}" | tee -a "${LOG_DIR}/instantiator.log"
else
	# automatic currently not implemented by design
	if ! "${INST_DIR}/automatic_instantiator.sh" "${IMAGE_YAML_NAME}" | tee -a "${LOG_DIR}/instantiator.log"; then
		die "Automatic instantiation not implemented"
	fi
fi

# Fallback: accept legacy path at repo root if present
if [[ ! -f ${CURRENT_NODE_FILE} ]]; then
	if [[ -f ${ALT_NODE_FILE} ]]; then
		CURRENT_NODE_FILE=${ALT_NODE_FILE}
	else
		die "Node name file not found: ${CURRENT_NODE_FILE}. Ensure Phase 1 saved the node hostname."
	fi
fi
NODE_NAME=$(<"${CURRENT_NODE_FILE}")
[[ -n ${NODE_NAME} ]] || die "Empty node name read from ${CURRENT_NODE_FILE}"
log "Target node: ${NODE_NAME}"

# --- Phase 2: Project preparation ---
log "Phase 2/4: Project preparation (FE copies + node setup)"

# Ensure node is deployed and SSH is available; deploy if necessary
wait_for_ssh() {
	local host="$1"
	local timeout="${2:-600}"
	local start end
	start=$(date +%s)
	while true; do
		if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${host}" 'echo ok' >/dev/null 2>&1; then
			return 0
		fi
		end=$(date +%s)
		if ((end - start > timeout)); then
			return 1
		fi
		sleep 3
	done
}

if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${NODE_NAME}" 'echo ok' >/dev/null 2>&1; then
	if command -v kadeploy3 >/dev/null 2>&1; then
		log_warn "SSH not ready on ${NODE_NAME}. Deploying image via kadeploy3..."
		if ! kadeploy3 -a "${HOME}/envs/img-files/${IMAGE_YAML_NAME}" -m "${NODE_NAME}" | tee -a "${LOG_DIR}/kadeploy.log"; then
			die "kadeploy3 failed for ${NODE_NAME}. Check ${LOG_DIR}/kadeploy.log"
		fi
		log_info "Waiting for SSH to come up on ${NODE_NAME}..."
		set +e
		wait_for_ssh "${NODE_NAME}" 900
		wst=$?
		set -e
		if [[ ${wst} -ne 0 ]]; then
			die "Timed out waiting for SSH on ${NODE_NAME} (waited 900s). Verify deployment succeeded."
		fi
		log_success "SSH is now available on ${NODE_NAME}."
	else
		log_warn "kadeploy3 not available; deploy manually: kadeploy3 -a ${HOME}/envs/img-files/${IMAGE_YAML_NAME} -m ${NODE_NAME}"
	fi
fi
PREP_FE_DIR="${BIN_DIR}/project-preparation/on-fe"
"${PREP_FE_DIR}/prepare_on_fe.sh" \
	--node "${NODE_NAME}" \
	--config "${CONFIG_PATH}" \
	--os-type "${OS_DIST_TYPE}" \
	--logs "${LOG_DIR}"

# Attempt to run prepare on node (will fallback to manual if ssh not available)
if ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${NODE_NAME}" 'echo ok' >/dev/null 2>&1; then
	log "Running on-node preparation script remotely"
	LOG_FILE="${LOG_DIR}/prepare_on_machine.log" ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" \
		"bash -lc 'export SELECTED_PARAMS_B64=${SELECTED_LINES_B64:-}; ~/experiments_node/on-machine/prepare_on_machine.sh'"
else
	log "SSH not available. Please run on the node: ~/experiments_node/on-machine/prepare_on_machine.sh"
fi

# --- Phase 3: Delegate experiments ---
log_step "Phase 3/4: Delegating experiments on node"
if ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" 'echo ok' >/dev/null 2>&1; then
	log_info "Starting delegation and live log stream from ${NODE_NAME}"
	# Stream run_delegator.sh output directly; run_delegator already tees to its log.
	set +e
	set +o pipefail
	trap - ERR
	ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" bash -lc \
		"'export SELECTED_PARAMS_B64=${SELECTED_LINES_B64:-}; CONFIG_JSON=~/experiments_node/config.json; if command -v stdbuf >/dev/null 2>&1; then stdbuf -oL -eL ~/experiments_node/on-machine/run_delegator.sh; else ~/experiments_node/on-machine/run_delegator.sh; fi'" 2>&1 |
		while IFS= read -r line; do
			ts=$(date +%H:%M:%S)
			printf '[%s] [INFO]  [%s] %s\n' "${ts}" "${NODE_NAME}" "${line}" 2>/dev/null || true
		done
	deleg_rc=${PIPESTATUS[0]}
	trap __on_err ERR
	set -o pipefail
	set -e

	if [[ ${deleg_rc:-0} -ne 0 ]]; then
		log_warn "Delegator failed (rc=${deleg_rc}). Exiting and reverting selection."
		exit "${deleg_rc}"
	fi
	FE_BATCH_OK=1
else
	log "SSH not available. Please run on the node: CONFIG_JSON=~/experiments_node/config.json ~/experiments_node/on-machine/run_delegator.sh"
fi

log_step "Phase 4/4: Transferring experiment artifacts"

if [[ -z ${COLLECT_BASE_PATH} ]]; then
	log_info "No collection base_path defined; skipping artifact transfer."
else
	FE_COLLECTION_ROOT="${HOME}/collected/${COLLECT_BASE_PATH}"
	mkdir -p "${FE_COLLECTION_ROOT}" || die "Failed to create FE collection root: ${FE_COLLECTION_ROOT}"
	# Build rule map (label -> pattern)
	declare -A RULE_MAP=()
	rules_count=$(jq 'length' <<<"${COLLECT_LOOKUP_RULES_JSON}")
	for ((ri = 0; ri < rules_count; ri++)); do
		entry=$(jq -c ".[${ri}]" <<<"${COLLECT_LOOKUP_RULES_JSON}")
		label=$(jq -r 'keys[0]' <<<"${entry}")
		pattern=$(jq -r '.[keys[0]]' <<<"${entry}")
		RULE_MAP["${label}"]="${pattern}"
	done

	transf_count=$(jq 'length' <<<"${COLLECT_FTRANSFERS_JSON}")
	if ((transf_count == 0)); then
		log_info "No ftransfers defined; nothing to collect."
	fi

	for ((ti = 0; ti < transf_count; ti++)); do
		look_into=$(jq -r ".[${ti}].look_into" <<<"${COLLECT_FTRANSFERS_JSON}")
		subfolder=$(jq -r ".[${ti}].transfer_to_subfolder_of_base_path" <<<"${COLLECT_FTRANSFERS_JSON}")
		mapfile -t look_for < <(jq -r ".[${ti}].look_for[]" <<<"${COLLECT_FTRANSFERS_JSON}" || true)
		if [[ -z ${look_into} || -z ${subfolder} ]]; then
			log_warn "Skipping transfer index ${ti}: missing look_into or subfolder"
			continue
		fi
		DEST_DIR="${FE_COLLECTION_ROOT}/${subfolder}"
		mkdir -p "${DEST_DIR}" || die "Failed creating destination: ${DEST_DIR}"
		# Build remote pattern list from rule labels
		patterns=()
		for lbl in "${look_for[@]}"; do
			pat="${RULE_MAP[${lbl}]:-}"
			if [[ -n ${pat} ]]; then
				patterns+=("${pat}")
			fi
		done
		if ((${#patterns[@]} == 0)); then
			log_warn "Transfer ${ti}: no patterns resolved from labels (${look_for[*]})"
			continue
		fi
		# Remote script: verify directory, enumerate matches safely (no local expansion), print unique list
		remote_script=$(
			cat <<'RSCRIPT'
set -Eeuo pipefail
dir="$1"; shift || true
if [[ ! -d "$dir" ]]; then exit 3; fi
cd "$dir" || exit 4
shopt -s nullglob
declare -A seen=()
for pat in "$@"; do
  for rf in $pat; do
    if [[ -f "$rf" ]]; then
      if [[ -z ${seen[$rf]+x} ]]; then
        printf '%s\n' "$rf"
        seen[$rf]=1
      fi
    fi
  done
done
RSCRIPT
		)
		# Assemble ssh command with patterns passed as args to avoid quoting issues
		mapfile -t REMOTE_FILES < <(ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" bash -lc "'${remote_script//$'\n'/\\n}' '${look_into}' ${patterns[*]@Q}" 2>/dev/null || true)
		# Exit codes 3/4 mean directory missing / cd failed
		if ((${#REMOTE_FILES[@]} == 0)); then
			# Check if remote dir exists to refine warning
			if ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" "test -d '${look_into}'" 2>/dev/null; then
				log_warn "Transfer ${ti}: no files matched in ${look_into} (patterns: ${look_for[*]})"
			else
				log_warn "Transfer ${ti}: directory ${look_into} does not exist"
			fi
			continue
		fi
		log_info "Transfer ${ti}: ${#REMOTE_FILES[@]} unique files from ${look_into} -> ${DEST_DIR} (patterns: ${look_for[*]})"
		copied=0 failed=0
		for f in "${REMOTE_FILES[@]}"; do
			# Skip if contains slash (should not in non-recursive mode)
			if [[ ${f} == */* ]]; then
				log_debug "Skipping nested path '${f}'"
				continue
			fi
			if scp -q -o StrictHostKeyChecking=no "root@${NODE_NAME}:${look_into%/}/${f}" "${DEST_DIR}/${f}"; then
				((copied++)) || true
			else
				((failed++)) || true
				log_warn "Failed to copy ${look_into%/}/${f}"
			fi
		done
		if ((failed > 0)); then
			log_warn "Transfer ${ti} partial: copied=${copied} failed=${failed} total=${#REMOTE_FILES[@]}"
		else
			log_success "Transfer ${ti} completed: ${copied}/${#REMOTE_FILES[@]} files copied."
		fi
	done
fi

log_success "All phases completed. Logs at: ${LOG_DIR}"

# Mark FE selection success so done.txt batch is retained
FE_BATCH_OK=1
