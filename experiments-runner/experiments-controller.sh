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
		if [[ ${LOG_LEVEL:-info} == debug ]]; then
			log_debug "Transfer ${ti}: building pattern list from labels: ${look_for[*]}"
		fi
		patterns=()
		for lbl in "${look_for[@]}"; do
			pat="${RULE_MAP[${lbl}]:-}"
			if [[ -n ${pat} ]]; then
				patterns+=("${pat}")
				if [[ ${LOG_LEVEL:-info} == debug ]]; then
					case "${pat}" in *[*?[]*) gtype=glob ;; *) gtype=literal ;; esac
					log_debug "Transfer ${ti}: label='${lbl}' pattern='${pat}' type=${gtype}"
				fi
			fi
		done
		# Always show patterns used at info level to tie filenames to patterns
		log_info "Transfer ${ti}: patterns used (raw) = ${patterns[*]} (labels: ${look_for[*]})"
		if ((${#patterns[@]} == 0)); then
			log_warn "Transfer ${ti}: no patterns resolved from labels (${look_for[*]})"
			continue
		fi
		# Remote script: verify directory, enumerate matches (need remote shell glob expansion). We
		# intentionally do NOT double-quote the patterns when invoking the script so the remote shell
		# expands them in the inner loop. Patterns that don't match expand to themselves unless nullglob is on;
		# we enable nullglob so unmatched patterns vanish (prevent spurious literal pattern names).
		if [[ ${LOG_LEVEL:-info} == debug ]]; then
			log_debug "Transfer ${ti}: summary — node='${NODE_NAME}' dir='${look_into}' dest='${DEST_DIR}' non-recursive=true regular-files-only=true dedup=true"
		fi
		# Remote pre-scan: show how many entries and regular files exist and list all entries; also show per-pattern matches
		PATTERNS_GLOBS_PRE=$(printf '%s ' "${patterns[@]}")
		REMOTE_PRESCAN=$(ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" LOOK_INTO_REMOTE="${look_into}" PATTERNS_GLOBS="${PATTERNS_GLOBS_PRE% }" bash -lc $'cat > /tmp/__prescan.sh <<"PREEOF"
set +u
set -o pipefail
shopt -s nullglob
# Print counts and list entries in current dir
echo PRE:pwd="$PWD"
entries_total=$(find . -maxdepth 1 -mindepth 1 -printf . 2>/dev/null | wc -c | tr -d "[:space:]")
reg_total=$(find . -maxdepth 1 -mindepth 1 -type f -printf . 2>/dev/null | wc -c | tr -d "[:space:]")
echo PRE:entries_total="$entries_total"
echo PRE:regular_total="$reg_total"
find . -maxdepth 1 -mindepth 1 -print 2>/dev/null | sed -e 's#^\./##' -e 's#^#PRE:list:#' || true
# Per-pattern matches
for p in ${PATTERNS_GLOBS% }; do
  echo PREPAT:pattern:"$p"
  found=0
  for rf in $p; do
    [ -f "$rf" ] || continue
    echo PREPAT:match:"$p":"$rf"
    found=1
  done
  if [ $found -eq 0 ]; then
    echo PREPAT:nomatch:"$p"
  fi
done
PREEOF
cd "${LOOK_INTO_REMOTE}" 2>/dev/null || { echo PRE:missing=1; exit 0; }
bash /tmp/__prescan.sh 2>/dev/null || true
rm -f /tmp/__prescan.sh
' 2>/dev/null || true)
		# Log concise prescan summary and details
		if [[ -n ${REMOTE_PRESCAN} ]]; then
			if printf '%s\n' "${REMOTE_PRESCAN}" | grep -q '^PRE:missing=1'; then
				die "Transfer ${ti} configuration error: source directory does not exist on node: ${look_into}"
			else
				SRC_ENTRIES=$(printf '%s\n' "${REMOTE_PRESCAN}" | sed -n 's/^PRE:entries_total="\([0-9]\+\)".*/\1/p' | head -1)
				SRC_REGULAR=$(printf '%s\n' "${REMOTE_PRESCAN}" | sed -n 's/^PRE:regular_total="\([0-9]\+\)".*/\1/p' | head -1)
				log_info "Transfer ${ti} source prescan: entries=${SRC_ENTRIES:-0}, regular_files=${SRC_REGULAR:-0}"
				# List all entries (top-level)
				printf '%s\n' "${REMOTE_PRESCAN}" | sed -n 's/^PRE:list://p' | while IFS= read -r E; do
					[[ -n ${E} ]] && log_info "SRC: ${E}"
				done
				# Per-pattern matched files
				for p in "${patterns[@]}"; do
					log_info "SRC:pattern '${p}' -> matches:"
					# Escape pattern for sed delimiter
					PE=$(printf '%s' "${p}" | sed 's/[\\.*\[\]\^$]/\\&/g')
					printf '%s\n' "${REMOTE_PRESCAN}" | sed -n "s/^PREPAT:match:\"${PE}\":\"\(.*\)\"/\1/p" | while IFS= read -r M; do
						log_info "SRC:  ${M}"
					done
					if printf '%s\n' "${REMOTE_PRESCAN}" | grep -q "^PREPAT:nomatch:\"${PE}\"$"; then
						log_info "SRC:  <no matches>"
					fi
				done
			fi
		fi
		remote_script=$(
			cat <<'RSCRIPT'
set -Eeuo pipefail
dir="$1"; shift || true
if [[ ! -d "$dir" ]]; then exit 3; fi
cd "$dir" || exit 4
shopt -s nullglob
# Reconstruct original pattern tokens from env (space-delimited)
IFS=' ' read -r -a _raw <<<"${PATTERNS_GLOBS:-}" || true
declare -A seen=()
for pat in "${_raw[@]}"; do
	# Expand pattern by iterating over matched filenames (nullglob removes unmatched)
	# Use an indirection loop that tolerates set -u by localizing rf
	for rf in $pat; do
		[[ -f "$rf" ]] || continue
		if [[ -z ${seen[$rf]+x} ]]; then
			printf '%s\n' "$rf"
			seen[$rf]=1
		fi
	done
done
RSCRIPT
		)
		PATTERNS_GLOBS=$(printf '%s ' "${patterns[@]}")
		# Capture raw output (even if empty) for debug analysis, also capture exit status
		REMOTE_RAW=$(ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" "PATTERNS_GLOBS=${PATTERNS_GLOBS% } bash -lc $'${remote_script//$'\n'/\n}' '${look_into}'; printf '__RC__:%s' $?" 2>/dev/null || true)
		REMOTE_RC=0
		if [[ ${REMOTE_RAW} == *'__RC__:'* ]]; then
			REMOTE_RC=${REMOTE_RAW##*__RC__:}
			REMOTE_RAW=${REMOTE_RAW%__RC__:*}
		fi
		if [[ ${LOG_LEVEL:-info} == debug ]]; then
			log_debug "Transfer ${ti}: remote enumeration exit code=${REMOTE_RC}; patterns tokens='${PATTERNS_GLOBS% }'"
			# For every literal pattern, pre-check existence of that exact file (non-glob) remotely
			for idx in "${!patterns[@]}"; do
				p=${patterns[${idx}]}
				if [[ ${p} != *[*?[]* ]]; then
					LIT_EXISTS=$(ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" "bash -lc 'cd ${look_into} 2>/dev/null || exit 0; [[ -f \"${p}\" ]] && echo present || echo absent'" 2>/dev/null || true)
					log_debug "Transfer ${ti}: literal_check pattern='${p}' -> ${LIT_EXISTS}"
				fi
			done
		fi
		IFS=$'\n' read -r -d '' -a REMOTE_FILES < <(printf '%s' "${REMOTE_RAW}" && printf '\0') || true
		# Exit codes 3/4 mean directory missing / cd failed
		if ((${#REMOTE_FILES[@]} == 0)); then
			# Check if remote dir exists to refine behavior
			if ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" "test -d '${look_into}'" 2>/dev/null; then
				log_warn "Transfer ${ti}: no files matched in ${look_into} (patterns labels: ${look_for[*]} ; raw patterns: ${patterns[*]})"
				# FE destination summary: what is currently there, and how patterns compare locally
				DEST_COUNT=$(find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c | tr -d '[:space:]' || true)
				log_info "Transfer ${ti} FE destination pre-state: '${DEST_DIR}' entries=${DEST_COUNT:-0}"
				if [[ ${DEST_COUNT:-0} -gt 0 ]]; then
					log_info "Transfer ${ti} FE destination first entries:"
					find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -20 | sed 's/^/FE: /' | while IFS= read -r L; do log_info "${L}"; done
					# Compare first entries to patterns (name-based)
					mapfile -t __FE_SAMPLES < <(find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -20 || true)
					for __fname in "${__FE_SAMPLES[@]}"; do
						match_list=()
						for p in "${patterns[@]}"; do
							# shellcheck disable=SC2053
							if [[ ${__fname} == ${p} ]]; then match_list+=("${p}"); fi
						done
						if ((${#match_list[@]} > 0)); then
							log_info "FE:REASON: file '${__fname}' matches patterns: ${match_list[*]}"
						else
							log_info "FE:REASON: file '${__fname}' matches no provided patterns"
						fi
					done
					# Per-pattern counts at destination
					DEST_PER_PATTERN=()
					for p in "${patterns[@]}"; do
						# Use local shell globbing inside a subshell to avoid polluting state
						cnt=$(bash -lc "shopt -s nullglob; cd '${DEST_DIR}' 2>/dev/null || exit 0; set -- ${p}; echo \$#" 2>/dev/null || true)
						cnt=${cnt:-0}
						DEST_PER_PATTERN+=("'${p}'=${cnt}")
					done
					log_info "Transfer ${ti} FE destination per-pattern matches: ${DEST_PER_PATTERN[*]}"
				fi
				# Always gather a concise diagnostic summary to explain the zero-match
				REMOTE_DEEP_DIAG=$(ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" LOOK_INTO_REMOTE="${look_into}" PATTERNS_GLOBS="${PATTERNS_GLOBS% }" bash -lc $'cat > /tmp/__deep_diag.sh <<"DIAGEOF"
set +u
set -o pipefail
shopt -s nullglob
echo DIAG:pwd="${PWD}"
echo DIAG:whoami="$(whoami)"
echo DIAG:shellopts="$-"
echo DIAG:patterns_raw="${PATTERNS_GLOBS% }"
# Total entries in directory (includes dirs)
entries_count=$(ls -A1 2>/dev/null | wc -l | tr -d "[:space:]")
echo DIAG:entries_count="$entries_count"
# List every regular file with size and mtime for context
echo DIAG:all_files_begin
for f in *; do
	[ -f "$f" ] || continue
	sz=$(wc -c <"$f" 2>/dev/null || echo 0)
	mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
	echo DIAG:file_meta:"$f":size="$sz":mtime_epoch="$mt"
done
echo DIAG:all_files_end
# Count plain files
plain_count=0; for f in *; do [ -f "$f" ] && plain_count=$((plain_count+1)); done
echo DIAG:plain_file_count="$plain_count"
echo DIAG:first_entries_start
ls -1 | head -50 || true
echo DIAG:first_entries_end
# Per-pattern detailed expansion
for p in ${PATTERNS_GLOBS% }; do
	is_glob=no
	case "$p" in *[*?[]* ) is_glob=yes;; esac
	echo DIAG:pattern_header:"$p":glob="$is_glob"
	count=0
	for rf in $p; do
		[ -f "$rf" ] || continue
		count=$((count+1))
		sz=$(wc -c <"$rf" 2>/dev/null || echo 0)
		mt=$(stat -c %Y "$rf" 2>/dev/null || echo 0)
		echo DIAG:match:"$p":"$rf":size="$sz":mtime_epoch="$mt"
	done
	if [ $count -eq 0 ]; then
		echo DIAG:pattern_no_matches:"$p"
	fi
	echo DIAG:pattern_count:"$p":count="$count"
done
# Additional diagnostics: show nullglob state & environment subset
shopt -p nullglob
echo DIAG:env_HOME="$HOME"
echo DIAG:env_USER="$USER"
DIAGEOF
cd "${LOOK_INTO_REMOTE}" 2>/dev/null || true
bash /tmp/__deep_diag.sh 2>&1 || true
rm -f /tmp/__deep_diag.sh
' 2>/dev/null || true)
				# Parse and log a concise summary at info level
				if [[ -n ${REMOTE_DEEP_DIAG} ]]; then
					ENTRIES_COUNT=$(printf '%s\n' "${REMOTE_DEEP_DIAG}" | sed -n 's/^DIAG:entries_count="\([0-9]\+\)".*/\1/p' | head -1)
					PLAIN_COUNT=$(printf '%s\n' "${REMOTE_DEEP_DIAG}" | sed -n 's/^DIAG:plain_file_count="\([0-9]\+\)".*/\1/p' | head -1)
					NULLGLOB_STATE=$(printf '%s\n' "${REMOTE_DEEP_DIAG}" | sed -n 's/^shopt -\([su]\) nullglob$/\1/p' | head -1)
					case "${NULLGLOB_STATE}" in s) NULLGLOB_STATE="on" ;; u) NULLGLOB_STATE="off" ;; *) NULLGLOB_STATE="unknown" ;; esac
					# Build per-pattern counts summary
					PER_PATTERN_SUMMARY=()
					for p in "${patterns[@]}"; do
						P_ESC=$(printf '%s' "${p}" | sed 's/[\\.*\[\]\^$]/\\&/g')
						cnt=$(printf '%s\n' "${REMOTE_DEEP_DIAG}" | sed -n "s/^DIAG:pattern_count:\"${P_ESC}\":count=\"\([0-9]\+\)\".*/\1/p" | head -1 || true)
						cnt=${cnt:-0}
						PER_PATTERN_SUMMARY+=("'${p}'=${cnt}")
					done
					log_info "Transfer ${ti} diagnosis: dir_entries=${ENTRIES_COUNT:-0}, regular_files=${PLAIN_COUNT:-0}, nullglob=${NULLGLOB_STATE}"
					log_info "Transfer ${ti} per-pattern matches: ${PER_PATTERN_SUMMARY[*]}"
					# Show a few example regular files if any exist
					if [[ ${PLAIN_COUNT:-0} -gt 0 ]]; then
						EX_SAMPLES=$(printf '%s\n' "${REMOTE_DEEP_DIAG}" | awk -F: '/^DIAG:file_meta:/{print $3" (size="gensub(/^size="/,"","g",$4)")"}' | head -5 | tr '\n' ', ' | sed 's/, $//')
						[[ -n ${EX_SAMPLES} ]] && log_info "Transfer ${ti} sample files: ${EX_SAMPLES}"
					fi
					# Heuristic suggestions (printed regardless of debug to aid next runs)
					for p in "${patterns[@]}"; do
						if [[ ${p} != *[*?[]* ]]; then
							log_info "Hint: pattern '${p}' is treated as a literal (no wildcards). If you intended an extension, use '*.${p}'."
						fi
						if [[ ${p} == */* ]]; then
							log_info "Note: pattern '${p}' includes a slash; collector is non-recursive and only matches files directly in ${look_into}."
						fi
					done
					# Additional classification line
					MATCH_COUNT_TOTAL=$(printf '%s\n' "${REMOTE_DEEP_DIAG}" | grep -c '^DIAG:match:' || true)
					if [[ ${ENTRIES_COUNT:-0} -eq 0 ]]; then
						log_info "Transfer ${ti} classification: dir_empty (no entries in directory)."
					elif [[ ${PLAIN_COUNT:-0} -eq 0 && ${ENTRIES_COUNT:-0} -gt 0 ]]; then
						log_info "Transfer ${ti} classification: only_directories (no regular files present at top level)."
					elif [[ ${MATCH_COUNT_TOTAL} -eq 0 && ${PLAIN_COUNT:-0} -gt 0 ]]; then
						log_info "Transfer ${ti} classification: patterns_mismatch (regular files exist but did not match the given patterns)."
					else
						log_info "Transfer ${ti} classification: unknown; inspect full diagnostics with --verbose."
					fi
				fi
				# Locator hints: probe nearby directories and a shallow recursive search under EXEC_DIR
				ALT_DIRS=()
				if [[ ${look_into} == */result ]]; then ALT_DIRS+=("${look_into%/result}/results"); fi
				if [[ ${look_into} == */results ]]; then ALT_DIRS+=("${look_into%/results}/result"); fi
				ALT_DIRS+=("${EXEC_DIR%/}/results" "${EXEC_DIR%/}/result")
				# Deduplicate and drop the original look_into if present
				DEDUP_ALT=()
				for __d in "${ALT_DIRS[@]}"; do
					[[ ${__d} == "${look_into}" ]] && continue
					skip=false
					for __e in "${DEDUP_ALT[@]:-}"; do
						if [[ ${__d} == "${__e}" ]]; then
							skip=true
							break
						fi
					done
					${skip} || DEDUP_ALT+=("${__d}")
				done
				if ((${#DEDUP_ALT[@]} > 0)); then
					ALT_DIRS_STR=$(printf '%s ' "${DEDUP_ALT[@]}")
					LOCATOR_OUT=$(ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" ALT_DIRS="${ALT_DIRS_STR% }" PATTERNS_GLOBS="${PATTERNS_GLOBS% }" EXEC_DIR_REMOTE="${EXEC_DIR}" bash -lc $'cat > /tmp/__locator.sh <<"LOCEOF"
set +u
set -o pipefail
shopt -s nullglob
# Probe alternative directories non-recursively
for d in ${ALT_DIRS}; do
  if [ -d "$d" ]; then
    entries=$(ls -A1 "$d" 2>/dev/null | wc -l | tr -d "[:space:]")
    plain=0; while IFS= read -r f; do [ -f "$d/$f" ] && plain=$((plain+1)); done < <(ls -A1 "$d" 2>/dev/null || true)
    echo LOC:dir:"$d":entries="$entries":plain="$plain"
    cd "$d" 2>/dev/null || continue
    for p in ${PATTERNS_GLOBS% }; do
      cnt=0
      for rf in $p; do [ -f "$rf" ] && cnt=$((cnt+1)); done
      echo LOC:pattern_count_dir:"$d":"$p":count="$cnt"
    done
    echo LOC:first_files_dir:"$d"
    ls -1 | head -10 | sed "s/^/LOC:file:\\"$d\\":\\"/;s/$/\\"/" || true
  else
    echo LOC:dir_missing:"$d"
  fi
done
# Shallow recursive search under EXEC_DIR (depth<=3)
if [ -d "${EXEC_DIR_REMOTE}" ]; then
  for p in ${PATTERNS_GLOBS% }; do
    echo LOC:search_under:"${EXEC_DIR_REMOTE}":pattern:"$p"
    # Note: -name uses glob-like patterns
	find "${EXEC_DIR_REMOTE}" -maxdepth 3 -type f -name "$p" -printf '%T@ %p\\n' 2>/dev/null | sort -nr | head -10 | cut -d' ' -f2- | sed 's/^/LOC:found: /'
  done
fi
LOCEOF
bash /tmp/__locator.sh 2>&1 || true
rm -f /tmp/__locator.sh
' 2>/dev/null || true)
					if [[ -n ${LOCATOR_OUT} ]]; then
						log_info "Locator hints BEGIN"
						# Print only concise lines at info level; full raw is acceptable as it is short
						printf '%s\n' "${LOCATOR_OUT}" | sed -n '1,200p' | while IFS= read -r L; do
							[[ -n ${L} ]] && log_info "${L}"
						done
						log_info "Locator hints END"
					fi
				fi
				# Full diagnostics only under debug to avoid excessive noise
				if [[ ${LOG_LEVEL:-info} == debug ]]; then
					log_debug "Transfer ${ti}: deep diagnostics BEGIN\n${REMOTE_DEEP_DIAG}\nTransfer ${ti}: deep diagnostics END"
				fi
			else
				die "Transfer ${ti} configuration error: directory does not exist on node: ${look_into}"
			fi
			continue
		fi
		# FE destination pre-state
		DEST_BEFORE_COUNT=$(find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c | tr -d '[:space:]' || true)
		log_info "Transfer ${ti}: ${#REMOTE_FILES[@]} unique files from ${look_into} -> ${DEST_DIR} (patterns: ${look_for[*]}), FE entries before=${DEST_BEFORE_COUNT:-0}"
		# Post-match reasoning: for each matched file, show which patterns it matches (local bash pattern match)
		if [[ ${LOG_LEVEL:-info} == debug ]]; then
			max_show=$((${#REMOTE_FILES[@]} < 50 ? ${#REMOTE_FILES[@]} : 50))
			for ((mi = 0; mi < max_show; mi++)); do
				fname=${REMOTE_FILES[${mi}]}
				matched_list=()
				for p in "${patterns[@]}"; do
					# shellcheck disable=SC2053 # we intentionally use pattern matching
					if [[ ${fname} == ${p} ]]; then
						matched_list+=("${p}")
					fi
				done
				if ((${#matched_list[@]} > 0)); then
					log_debug "REASON: file '${fname}' selected because it matched patterns: ${matched_list[*]}"
				else
					log_debug "REASON: file '${fname}' selected by remote script but did not match any local pattern check (possible mismatch in shell options)."
				fi
			done
		fi
		if [[ ${LOG_LEVEL:-info} == debug ]]; then
			printf '%s\n' "${REMOTE_FILES[@]:0:20}" | sed 's/^/DEBUG first-matches: /' || true
			((${#REMOTE_FILES[@]} > 20)) && log_debug "(only first 20 names logged)"
			# Provide origin reasoning (which patterns contributed to each file)
			for mf in "${REMOTE_FILES[@]}"; do
				orig_patterns=()
				for p in "${patterns[@]}"; do
					# shellcheck disable=SC2016,SC2154
					if ssh -o StrictHostKeyChecking=no "root@${NODE_NAME}" "bash -lc 'cd ${look_into} 2>/dev/null || exit 0; shopt -s nullglob; for __t in ${p}; do [ \"${__t}\" = \"${mf}\" ] && exit 0; done; exit 1'" 2>/dev/null; then
						orig_patterns+=("${p}")
					fi
				done
				log_debug "Transfer ${ti}: match_reason file='${mf}' from_patterns='${orig_patterns[*]:-<unknown>}'"
			done
		fi
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
		# FE destination post-state and summary
		DEST_AFTER_COUNT=$(find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -printf '.' 2>/dev/null | wc -c | tr -d '[:space:]' || true)
		DA=${DEST_AFTER_COUNT:-0}
		DB=${DEST_BEFORE_COUNT:-0}
		DELTA=$((DA - DB))
		log_info "Transfer ${ti} FE destination after copy: entries=${DA} (delta=${DELTA})"
		# Log first 10 files now present
		log_info "Transfer ${ti} FE destination first entries after copy:"
		find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -10 | sed 's/^/FE: /' | while IFS= read -r L; do log_info "${L}"; done
		# Compare first entries to patterns after copy
		mapfile -t __FE_SAMPLES2 < <(find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -10 || true)
		for __fname in "${__FE_SAMPLES2[@]}"; do
			match_list=()
			for p in "${patterns[@]}"; do
				# shellcheck disable=SC2053
				if [[ ${__fname} == ${p} ]]; then match_list+=("${p}"); fi
			done
			if ((${#match_list[@]} > 0)); then
				log_info "FE:REASON: file '${__fname}' matches patterns: ${match_list[*]}"
			else
				log_info "FE:REASON: file '${__fname}' matches no provided patterns"
			fi
		done
		# Destination per-pattern match counts
		DEST_PER_PATTERN_AFTER=()
		for p in "${patterns[@]}"; do
			cnt=$(bash -lc "shopt -s nullglob; cd '${DEST_DIR}' 2>/dev/null || exit 0; set -- ${p}; echo \$#" 2>/dev/null || true)
			cnt=${cnt:-0}
			DEST_PER_PATTERN_AFTER+=("'${p}'=${cnt}")
		done
		log_info "Transfer ${ti} FE destination per-pattern matches (after): ${DEST_PER_PATTERN_AFTER[*]}"
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
