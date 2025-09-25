# Experiments Runner Instructions Archive

This file records the controlling prompts/instructions for building the experiments-runner subproject so the context is preserved in-repo.

---

User “delivery prompt” (meta instructions to the AI agent)

"""
this is a prompt on how t odeliver what i want implemented. experiments-runner has to have it's own folder as there will be other components ill add later with other instructions. save these instructions in a file and start working on them. if you feel youve done a lot, like too much at once, make a pause and ask me to let you continue. prompt:

"""

---

Main implementation prompt

"""
Prompt for AI Agent — Build “experiments-runner” (Grid’5000 supporting infrastructure)
Mission

Create a production-quality experiments-runner subproject for Grid’5000 to automate: (1) machine instantiation, (2) project preparation (copying scripts + creating remote folder structure), (3) experiment delegation with parallel execution + live logs, and (4) results collection. Everything must be cleanly structured, well-named, thoroughly logged, and easy to debug.

You MUST:

Maintain a visible progress checklist (DONE/LEFT) and update it as you complete tasks.

For each step, write a short “What/Why/How” explanation and key design choices.

Produce readable shell scripts with defensive Bash patterns, strong error handling, and clear logs.

Implement OS-aware package installation (Debian, RHEL7, RHEL7+).

Provide a realistic README.md that teaches a new user how to run the system end-to-end on Grid’5000.

Global Standards

Languages: POSIX/Bash for scripts; JSON for configs; Markdown for docs.

Shell strict mode: set -Eeuo pipefail and IFS=$'\n\t'.

Error tracing: add trap for ERR to print file, line, and function when failing.

Logging: timestamps, log levels (INFO/WARN/ERROR/DEBUG), and component tags. Provide a tiny bin/utils/liblog.sh.

Naming:

Folders & scripts: kebab-case (e.g., machine-instantiator, experiments-controller.sh).

Bash variables & functions: UPPER_SNAKE for constants, lower_snake for vars & functions.

JSON keys: lower_snake.

Idempotency: scripts can be re-run safely (create-if-missing, skip-if-present).

Dry run: support --dry-run wherever sensible.

Configuration: One input experiment config JSON filename (e.g., csnn-faces.json), resolved inside a hardcoded absolute path to the experiments-configurations folder.

Compatibility note: The canonical key is "is_machine_instantiator_manual". If a config provides "is_machine_instantiator_automatic", treat it as the negation of "is_machine_instantiator_manual" (for backward compatibility), with a clear warning.

Directory / File Layout (create exactly)
experiments-runner/
├─ README.md
├─ experiments-controller.sh
├─ experiments-configurations/
│  ├─ _TEMPLATE.json        # template: see spec below
│  └─ csnn-faces.json       # example config using the template spec (include concrete sample)
└─ bin/
   ├─ machine-instantiator/
   │  ├─ manual-machine-start.sh
   │  └─ automatic-machine-start.sh   # must print TODO and exit 2 (not implemented)
   ├─ project-preparation/
   │  ├─ prepare-remote-structure.sh  # copies scripts, builds remote dirs, exports env
   │  └─ node-setup/
   │     ├─ install-dependencies.sh   # OS-aware installer (Debian/RHEL7/RHEL7+)
   │     └─ write-env.sh              # writes env vars to /etc/profile.d or ~/.profile
   ├─ experiments-delegator/
   │  ├─ on-fe/
   │  │  ├─ experiments-delegator.sh  # reads params, builds commands, streams logs
   │  │  └─ utils-params-tracker.sh   # tracker creation & diff logic
   │  └─ on-machine/
   │     └─ run-batch.sh              # cd to full_path_to_executable and run commands in parallel
   ├─ experiments-collector/
   │  ├─ on-machine/
   │  │  └─ csnn_collection.sh        # implements your collection strategy
   │  └─ on-fe/
   │     └─ (placeholder)             # keep structure even if empty
   └─ utils/
      ├─ liblog.sh
      ├─ libjson.sh                   # safe jq wrapper & helpers
      ├─ libremote.sh                 # ssh/scp wrappers with retries
      └─ libosdetect.sh               # maps os_distribution_type → pkg mgr

Create all files with executable bits where relevant, shebang #!/usr/bin/env bash, and headers describing purpose, inputs, outputs, exit codes.

Progress Checklist (update live as you work)

Maintain and print a list like this at the top of your output and after each major step:

 [ ] Create directory tree and placeholders
 [ ] Implement lib utilities (logging, JSON, remote, OS detect)
 [ ] Author _TEMPLATE.json and csnn-faces.json example
 [ ] Implement manual-machine-start.sh and automatic-machine-start.sh (stubbed)
 [ ] Implement prepare-remote-structure.sh + node-setup scripts
 [ ] Implement experiments-delegator (FE + machine) incl. tracker logic & parallel exec
 [ ] Implement csnn_collection.sh collection strategy
 [ ] Implement experiments-controller.sh orchestrator
 [ ] Write README.md with full usage & troubleshooting
 [ ] Smoke tests (dry-run + happy path)

Mark [x] as items complete. For each completed item, include What/Why/How notes.

Config JSONs

1) experiments-configurations/_TEMPLATE.json (generate exactly; note empty experiments_collection as requested)
{
  "running_experiments": {
    "on_fe": {
      "to_do_parameters_list_path": "path/to/parameters.txt"
    },
    "on_machine": {
      "execute_command": "./executable",
      "full_path_to_executable": "/absolute/path/to/executable"
    },
    "number_of_experiments_to_run_in_parallel_on_machine": 1,
    "experiments_collection": { }
  },
  "machine_setup": {
    "image_to_use": "my_image.yaml",
    "env_variables_list": [],
    "is_machine_instantiator_manual": true,
    "list_of_needed_libraries": "path/to/required-packages.txt",
    "os_distribution_type": 1
  }
}

2) experiments-configurations/csnn-faces.json (example for this project; include the two collection variables)
{
  "running_experiments": {
    "on_fe": {
      "to_do_parameters_list_path": "/ABSOLUTE/FE/PATH/params/csnn_params.txt"
    },
    "on_machine": {
      "execute_command": "./run_experiment",
      "full_path_to_executable": "/ABSOLUTE/MACHINE/PATH/csnn"
    },
    "number_of_experiments_to_run_in_parallel_on_machine": 5,
    "experiments_collection": {
      "collection_strategy": "csnn_collection.sh",
      "path_to_save_experiment_results_on_fe": "/ABSOLUTE/FE/PATH/results/csnn",
      "path_to_saved_experiment_results_on_machine": "/ABSOLUTE/MACHINE/PATH/results/csnn"
    }
  },
  "machine_setup": {
    "image_to_use": "csnn_image.yaml",
    "env_variables_list": [
      { "OMP_NUM_THREADS": "1" },
      { "CUDA_VISIBLE_DEVICES": "0" }
    ],
    "is_machine_instantiator_manual": true,
    "list_of_needed_libraries": "/ABSOLUTE/MACHINE/PATH/bootstrap/requirements.txt",
    "os_distribution_type": 1
  }
}

Hardcode the absolute path to experiments-configurations/ inside experiments-controller.sh, so the controller only needs the filename, e.g. csnn-faces.json.

Component Requirements
A) experiments-controller.sh (root orchestrator)

Responsibilities

Resolve input JSON filename against the hardcoded absolute experiments-configurations path; validate file exists/valid JSON.

Read:

machine_setup.is_machine_instantiator_manual (or invert is_machine_instantiator_automatic if present),

machine_setup.image_to_use, machine_setup.os_distribution_type, machine_setup.env_variables_list, machine_setup.list_of_needed_libraries,

running_experiments.on_fe.to_do_parameters_list_path,

running_experiments.on_machine.execute_command, full_path_to_executable,

running_experiments.number_of_experiments_to_run_in_parallel_on_machine,

running_experiments.experiments_collection block (JSON object, may be empty in TEMPLATE).

Step 1: Machine instantiation

If manual → run bin/machine-instantiator/manual-machine-start.sh.

Else → call bin/machine-instantiator/automatic-machine-start.sh which must echo "TODO" and exit with code 2 and message "not implemented yet".

Step 2: Project preparation

Run bin/project-preparation/prepare-remote-structure.sh to create remote folders, upload FE scripts, write env vars, and run dependency installer (node-setup/install-dependencies.sh) based on os_distribution_type.

Step 3: Experiment delegation

Run bin/experiments-delegator/on-fe/experiments-delegator.sh with the inputs:

number_of_experiments_to_run_in_parallel_on_machine

execute_command

full_path_to_executable

to_do_parameters_list_path

the raw JSON of the experiments_collection section (pass-through)

Stream remote logs to FE (e.g., via ssh tail -F or periodic rsync).

Step 4: Collection

After all dispatched jobs finish, trigger collection strategy (on machine), e.g., csnn_collection.sh.

Exit with 0 on success; non-zero with context on failure.

CLI

./experiments-controller.sh --config <FILENAME.json> [--dry-run] [--verbose]

Logging

Log each phase START/END + duration.

On failure, print the exact command, return code, and last 50 lines of relevant logs.

B) bin/machine-instantiator/

manual-machine-start.sh: placeholder to run the manual Grid’5000 node start; include a banner:

Prints instructions on what the user must do manually (reserve node, deploy image_to_use, etc.).

Echoes expected environment variables/SSH target format that other scripts assume (e.g., G5K_HOST, G5K_USER, G5K_SSH_KEY).

Validates that ssh connectivity succeeds (ssh -o BatchMode=yes ... true).

automatic-machine-start.sh: contents:

Print "TODO: automatic machine instantiation — not implemented yet" and exit 2 with message "not implemented yet".

C) bin/project-preparation/

prepare-remote-structure.sh:

Creates a clear remote directory tree under a base (e.g., ~/experiments_node/):

experiments_node/
├─ on-machine/
│  ├─ executables/
│  ├─ results/
│  ├─ logs/
│  ├─ collection/
│  └─ bootstrap/
└─ on-fe/
   └─ logs/   # (optional rsync target)

Uploads required scripts: on-machine/run-batch.sh, experiments-collector/on-machine/*.sh, and bootstrap files.

Exports env vars (see write-env.sh) and installs dependencies (see install-dependencies.sh).

Validates full_path_to_executable exists or is creatable; makes it executable if present.

node-setup/write-env.sh:

Reads env_variables_list (array of single-pair objects) and persists them:

Prefer /etc/profile.d/99-experiments.sh if sudo available; else append to ~/.profile.

For each var, record in a log which file was updated.

node-setup/install-dependencies.sh:

Input: os_distribution_type (1=Debian/apt, 2=RHEL7/yum, 3=RHEL7+/dnf), and a text file at list_of_needed_libraries with one package per line (ignore blanks/#).

Detect tool (apt-get, yum, dnf) and implement update + install with retries.

Example behavior:

Debian: apt-get update && apt-get install -y $(packages)

RHEL7: yum makecache && yum install -y $(packages)

RHEL7+: dnf makecache && dnf install -y $(packages)

Print a table-like summary of installed packages and any failures.

D) bin/experiments-delegator/

1) On Frontend (on-fe/experiments-delegator.sh)

Inputs:

--parallel N (from number_of_experiments_to_run_in_parallel_on_machine)

--execute-command CMD

--full-path EXEC_PATH

--params-file /path/to/parameters.txt

--collection-json '{...}' (raw JSON)

Behavior:

Validate inputs, JSON, and remote connectivity.

Use utils-params-tracker.sh to:

Find or create the tracker file ${params_file%.txt}_tracker.txt.

Compute TODO lines = params_file minus lines present in tracker (exact string match).

Select up to N TODO lines (or fewer if not enough).

Append the selected lines to the tracker immediately (so concurrent runs don’t double-book).

Build the command list by prefixing each selected line with execute_command, e.g.:

./run_experiment 5 5 2 4 800 44 8
./run_experiment 5 5 2 5 800 42 8
...

Upload the command list to the remote machine (e.g., ~/experiments_node/bootstrap/commands.pending).

Remotely call on-machine/run-batch.sh with:

--full-path EXEC_PATH

--commands-file ~/experiments_node/bootstrap/commands.pending

--parallel N

Stream logs from ~/experiments_node/logs/ during execution (tail or rsync loop).

Wait for all remote PIDs to finish; exit non-zero if any job failed.

When finished, parse --collection-json and trigger the collection strategy remotely.

Notes:

If there are fewer TODO lines than N, just run however many remain (including 0, with a friendly message).

Be explicit that all selected commands must run in parallel on the remote host; after they all complete, continue.

2) On Frontend helper (on-fe/utils-params-tracker.sh)

Deduplicates blank/comment lines.

tracker file format: copy of the exact lines scheduled (one per line).

Provides functions:

select_next_lines params_file tracker_file max_count >stdout

append_tracker tracker_file lines...

All functions log what they select/append.

3) On Machine (on-machine/run-batch.sh)

Inputs: --full-path /abs/path, --commands-file FILE, --parallel N.

Behavior:

cd to --full-path.

Read commands file; ensure at least 1 command unless told otherwise.

Launch commands in parallel with clear per-job logs (e.g., using background jobs or xargs -P):

Example: xargs -P "$N" -I{} bash -lc "{}" > "logs/job_$idx.out" 2> "logs/job_$idx.err"

Wait for all to complete; summarize exit codes.

Non-zero exit if any job failed; print failing commands.

E) bin/experiments-collector/
On Machine — csnn_collection.sh

Inputs (via environment or args):

path_to_saved_experiment_results_on_machine

path_to_save_experiment_results_on_fe

Behavior:

Validate both paths exist; create FE path remotely if needed (or accept pulling to FE via scp).

Find all *.txt under path_to_saved_experiment_results_on_machine.

Append/concatenate them into a single collected_results.txt under the FE path, preserving file names as headers.

Emit a summary (count of files, total lines).

This script is the default collection strategy referenced by "collection_strategy": "csnn_collection.sh".

(Also create an empty on-fe/ folder to preserve the on-fe/on-machine symmetry.)

Utilities (under bin/utils/)

liblog.sh: log_info, log_warn, log_error, log_debug, with timestamps and component name.

libjson.sh: safe jq wrappers; fail with message if jq missing; pretty-print helper.

libremote.sh: ssh_retry, scp_retry, options for key, user, host, control master, and timeouts.

libosdetect.sh: map os_distribution_type → {ID, pkg_mgr, install_cmd}; print chosen strategy.

README.md (write clearly)

Explain:

Purpose and architecture (diagram in ASCII ok).

File tree and roles.

How to prepare the config JSON (point out TEMPLATE vs project JSON differences).

How to run manual instantiation; what env vars must be exported (e.g., G5K_USER, G5K_HOST, G5K_SSH_KEY).

One-liner examples:

./experiments-controller.sh --config csnn-faces.json

overriding parallelism and dry-run examples.

Troubleshooting guide:

SSH failures, missing packages, invalid JSON, zero TODO lines, long-running jobs, partial failures.

Conventions (logs, trackers, where results land).

Exit codes table per script.

Acceptance Criteria & Tests

Tree exists exactly as specified.

All scripts have shebangs, set -Eeuo pipefail, traps, and helpful --help.

experiments-controller.sh:

Hardcodes absolute path to experiments-configurations/.

Accepts only the filename (e.g., csnn-faces.json).

Honors manual vs automatic mode behavior exactly (automatic prints TODO + exits 2 “not implemented yet”).

Phases 1→4 run in order and stop on error.

Delegation:

Tracker file ${params%.txt}_tracker.txt is created automatically.

Correctly selects up to N new lines; if fewer, runs the remainder.

Builds commands by prefixing execute_command and runs them in parallel on the remote machine.

Collection:

csnn_collection.sh concatenates all *.txt from machine path to FE path into collected_results.txt.

OS Install:

Given os_distribution_type ∈ {1,2,3}, chooses apt/yum/dnf and installs listed packages from list_of_needed_libraries.

Docs: README is sufficient for a new engineer to run everything.

Logs: clear start/end markers, per-job logs, and concise failure summaries.

Deliverables

The full directory tree with implemented scripts and configs.

A progress checklist printed and updated as you complete each task.

For each component, include a brief What/Why/How in your output.

A short smoke test transcript showing a dry run and a happy path invocation.

Notes & Edge Cases to Handle

Normalize weird quotes in JSON (convert smart quotes to ASCII); validate with jq.

If both is_machine_instantiator_manual and is_machine_instantiator_automatic appear, prefer is_machine_instantiator_manual and warn that the latter is ignored; otherwise, infer manual = !automatic.

Empty experiments_collection (TEMPLATE) must not break the pipeline; skip collection with a clear “no-op” notice.

If full_path_to_executable doesn’t exist, create the directory path and log a warning; do not invent the binary.

Respect file permissions (chmod +x) for scripts on upload.

Parallel exec must not exceed N; ensure you wait for all jobs.

Ensure tracker is append-only once selection is made to avoid double scheduling.

Begin now. As you progress, keep the checklist updated and include brief explanations for each completed step.
"""
