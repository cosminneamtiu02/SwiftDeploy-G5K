#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2154,SC2029,SC2312
set -euo pipefail
IFS=$'\n\t'

# -------- HARDCODED FOLDERS --------
BASE_DIR="$(pwd)"
PLACEHOLDER_FOLDER="grid5k-csnn"
CONFIGS_DIR="${BASE_DIR}/${PLACEHOLDER_FOLDER}/g5k_env_creator/configs"
NODE_SCRIPT_DIR="${BASE_DIR}/${PLACEHOLDER_FOLDER}/g5k_env_creator/node_build_scripts"
DEPLOYED_NODE_FILE="${BASE_DIR}/${PLACEHOLDER_FOLDER}/g5k_env_creator/current_deployed_node.txt"

# -------- USER INPUT --------
CONFIG_FILE="${1:-}" # e.g., csnn_ckplus.conf

if [[ -z ${CONFIG_FILE} ]]; then
	echo "Usage: $0 <config_file>"
	exit 1
fi

CONFIG_PATH="${CONFIGS_DIR}/${CONFIG_FILE}"

if [[ ! -f ${CONFIG_PATH} ]]; then
	echo "Error: Config file ${CONFIG_PATH} not found."
	exit 1
fi

# Load config variables (dynamic path; suppress SC1090)
# shellcheck source=/dev/null
source "${CONFIG_PATH}"

# -------- DERIVED VARIABLES (from sourced config) --------
TAR_FILE="${HOME}/envs/${GENERAL_NAME}.tar.zst"
YAML_FILE="${HOME}/${GENERAL_NAME}.yaml"
LOCAL_SCRIPT_PATH="${NODE_SCRIPT_DIR}/${SETUP_SCRIPT}"

# -------- PRE-CHECK 1: Clean up leftover node file if present --------
if [[ -f ${DEPLOYED_NODE_FILE} ]]; then
	echo "Warning: Found leftover ${DEPLOYED_NODE_FILE} — deleting it."
	rm -f "${DEPLOYED_NODE_FILE}"
fi

# -------- PRE-CHECK 2: Ensure target files do not already exist --------
if [[ -f ${TAR_FILE} ]]; then
	echo "ERROR: Tar file ${TAR_FILE} already exists. Please remove or rename it before running."
	exit 1
fi

if [[ -f ${YAML_FILE} ]]; then
	echo "ERROR: YAML file ${YAML_FILE} already exists. Please remove or rename it before running."
	exit 1
fi

if [[ ! -f ${LOCAL_SCRIPT_PATH} ]]; then
	echo "Error: Setup script file ${LOCAL_SCRIPT_PATH} not found."
	exit 1
fi

# -------- STEP 1: Deploy OS image --------
echo "Starting deployment of ${OS_NAME}..."
if ! deploy_output=$(kadeploy3 "${OS_NAME}" 2>&1); then
	echo "Deployment failed."
	echo "${deploy_output}"
	exit 1
fi

# Capture last node name from kadeploy3 output
node_name=$(printf '%s\n' "${deploy_output}" | tail -n 1 | awk '{print $1}')
if [[ -z ${node_name} ]]; then
	echo "Failed to extract machine name from deployment output."
	exit 1
fi

# Save node name persistently
echo "${node_name}" >"${DEPLOYED_NODE_FILE}"
echo "Captured and saved machine name to ${DEPLOYED_NODE_FILE}: ${node_name}"

# -------- STEP 2: Copy setup script to node --------
echo "Copying script to ${node_name}:/root/${SETUP_SCRIPT}..."
if ! scp "${LOCAL_SCRIPT_PATH}" "root@${node_name}:/root/${SETUP_SCRIPT}"; then
	echo "Failed to copy script."
	exit 1
fi

# -------- STEP 3: SSH into node and block --------
echo "Running script on ${node_name} (blocking terminal)..."
# shellcheck disable=SC2029
if ! ssh "root@${node_name}" "bash /root/${SETUP_SCRIPT}"; then
	echo "Script failed on remote node."
	exit 1
fi

# -------- STEP 4: Remove script from node --------
echo "Removing script from ${node_name}..."
# shellcheck disable=SC2029
if ! ssh "root@${node_name}" "rm /root/${SETUP_SCRIPT}"; then
	echo "Warning: Failed to remove script from remote node."
fi

# -------- STEP 5: Archive environment --------
echo "Running tgz-g5k..."
if ! tgz-g5k -m "${node_name}" -f "${TAR_FILE}"; then
	echo "Failed to archive environment image."
	exit 1
fi

# -------- CLEANUP: Delete node file --------
echo "Cleaning up ${DEPLOYED_NODE_FILE} after tgz-g5k step..."
rm -f "${DEPLOYED_NODE_FILE}"

# -------- STEP 6: Generate YAML --------
echo "Generating ${YAML_FILE}..."
if ! kaenv3 -p "${OS_NAME}" -u deploy >"${YAML_FILE}"; then
	echo "Failed to generate YAML environment file."
	exit 1
fi

# -------- STEP 7: Apply sed modifications --------
echo "Applying YAML modifications..."
sed -i "/^name:/c\name: ${YAML_NAME}" "${YAML_FILE}"
sed -i "/^alias:/c\alias: ${YAML_ALIAS}" "${YAML_FILE}"
sed -i "/^description:/c\description : ${YAML_DESCRIPTION}" "${YAML_FILE}"
sed -i "/^author:/c\author: ${YAML_AUTHOR}" "${YAML_FILE}"
sed -i "/^\s*file:/c\  file: /home/cneamtiu/envs/${GENERAL_NAME}.tar.zst" "${YAML_FILE}"

echo "Script finished successfully."
