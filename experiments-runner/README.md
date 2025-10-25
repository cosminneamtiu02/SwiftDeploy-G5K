# Experiments Runner (Grid'5000)

This subproject automates Grid'5000 experiment workflows:

1. Machine instantiation (manual for now)
2. Project preparation (remote structure, env, packages)
3. Experiment delegation (parallel, tracked, live logs)
4. Results collection

## Live Progress Checklist

- [x] Create directory tree and placeholders
- [x] Implement lib utilities (logging, JSON, remote, OS detect)
- [x] Author _TEMPLATE.json and csnn-faces.json example
- [x] Implement manual-machine-start.sh and automatic-machine-start.sh (stubbed)
- [x] Implement prepare-remote-structure.sh + node-setup scripts
- [x] Implement experiments-delegator (FE + machine) incl. tracker logic & parallel exec
- [x] Implement csnn_collection.sh collection strategy
- [x] Implement experiments-controller.sh orchestrator
- [x] Write README.md with full usage & troubleshooting (expand)
- [x] Smoke tests (dry-run + happy path)

## Architecture overview

```text
experiments-controller.sh (front-end orchestrator)
 ├─ bin/
 │    ├─ common/
 │    │    ├─ environment.sh      # shared path + logging bootstrap
 │    │    ├─ logging.sh          # thin wrapper around liblog
 │    │    ├─ file_transfer.sh    # scp/tar helpers (legacy)
 │    │    ├─ remote.sh           # upload + invoke remote scripts (legacy)
 │    │    └─ collector.sh        # JSON parsing + validation (legacy)
 │    ├─ selection/select_batch.sh
 │    ├─ provisioning/provision_machine.sh
 │    ├─ preparation/prepare_project_assets.sh
 │    ├─ execution/delegate_experiments.sh
 │    └─ collection/collect_artifacts.sh # shim -> pipeline/phase-collection
 │
 └─ pipeline/
   ├─ common/
   │    ├─ general-environment/environment.sh
   │    ├─ general-logging/logging.sh
   │    ├─ general-collector/
   │    │    ├─ artifact-collector-bundle.sh
   │    │    ├─ artifact-collector-logging.sh
   │    │    ├─ artifact-collector-transfer.sh
   │    │    ├─ collector-config.sh
   │    │    ├─ artifact-state.sh
   │    │    └─ file-transfer.sh
   │    └─ general-remote/remote.sh
   └─ phases/
     └─ phase-collection/
       ├─ collect-artifacts.sh
       └─ remote-tools/
         ├─ pre-scan.sh | enumerate.sh | deep-diag.sh
         ├─ locator.sh (alt-path discovery)
         └─ snapshot.sh (tar stream for racey outputs)
 └─ logs/

Remote layout on the target machine (created under the user’s home):

```text
~/experiments_node/
 on-machine/
  executables/   # optional helper binaries/scripts
  results/       # experiment outputs
  logs/          # per-job logs (job_N.out/err)
  collection/    # collection strategies (e.g., csnn_collection.sh)
  bootstrap/     # commands.pending, setup helpers
```

## Prerequisites

- Grid’5000 access and a reachable allocation/host

Environment expected for remote operations:

```bash
export G5K_USER=<user>
export G5K_HOST=<node.your-site.grid5000.fr>
export G5K_SSH_KEY=~/.ssh/id_rsa
```

Quick connectivity check:

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$G5K_SSH_KEY" "$G5K_USER@$G5K_HOST" true
```

## Quick start

1. Prepare a config JSON in `experiments-configurations/`.
  Copy `_TEMPLATE.json` to `my-exp.json` or start from `csnn-faces.json`.
2. Export environment variables `G5K_USER`, `G5K_HOST`, `G5K_SSH_KEY`.
3. Launch the full workflow (selection → instantiation → preparation → delegation → collection):

```bash
./experiments-runner/experiments-controller.sh --config csnn-faces.json --verbose
```

Logs stream to `experiments-runner/logs/`. Each phase appends to dedicated
`*.log` files inside the folder. State snapshots for troubleshooting reside under
`logs/controller_state.*` during the run and are cleaned up automatically on
success.

## Controller CLI

```bash
./experiments-runner/experiments-controller.sh --config <FILENAME.json> [--verbose]

Required:
  --config <filename>   JSON config relative to experiments-configurations/

Optional:
  --verbose             Promote log level to DEBUG for all phases
```

## Configuration schema

The controller resolves the config by filename inside
`experiments-runner/experiments-configurations/`.

Important fields (see `_TEMPLATE.json`):

- `machine_setup`
  - `is_machine_instantiator_manual` (boolean). If absent but
    `is_machine_instantiator_automatic` exists, it is inverted with a warning.
  - `os_distribution_type` (int): 1=Debian/apt, 2=RHEL7/yum, 3=RHEL7+/dnf
  - `env_variables_list` (array of single-key objects): persisted via `write-env.sh`
- `running_experiments.on_fe`
  - `to_do_parameters_list_path` (string): absolute path on FE with parameters
    (one per line)
- `running_experiments.on_machine`
  - `execute_command` (string): command to prefix to each params line
  - `full_path_to_executable` (string): absolute working directory or binary path
    on the machine
- `running_experiments.number_of_experiments_to_run_in_parallel_on_machine` (int)
- `running_experiments.experiments_collection` (object; may be empty)
  - Example keys for built-in strategy:
    - `collection_strategy`: "csnn_collection.sh"
    - `path_to_saved_experiment_results_on_machine`: directory containing *.txt
      results
    - `path_to_save_experiment_results_on_fe`: output directory for the combined file

Tip: Start from `_TEMPLATE.json` and replace absolute paths and values.

## Phase details

- Runs `manual-machine-start.sh` (validates SSH) or `automatic-machine-start.sh` (stub; exits 2).
- Creates the remote tree under `~/experiments_node/on-machine/` and uploads
    `run-batch.sh` and collection scripts.
- Persists env vars with `write-env.sh`. Package installation from config has
    been removed; perform any dependency setup inside your image or manually.
- `on-fe/experiments-delegator.sh` selects up to N TODO lines from the params file
    using a tracker `*_tracker.txt` (same folder).
- Uploads a `commands.pending` file to the remote bootstrap folder and calls
    `on-machine/run-batch.sh` with `--parallel N`.
- Streams remote logs from `~/experiments_node/on-machine/logs/`
    (use `--no-stream` to disable).
- Phase 4 now drives a reusable collector pipeline: prescan → quickcheck →
    enumeration → copy.
- Remote helpers live in `pipeline/phases/phase-collection/remote-tools/` and are uploaded
  automatically per run.
- Default `csnn_collection.sh` remains available for manual use, but the
    controller primarily relies on lookup rules + file transfer directives
    defined in the config JSON.

## Delegation & tracker behavior

- The tracker file is `${params_file%.txt}_tracker.txt` next to your params file.
- TODO lines = params minus tracker (exact string match after trimming and
  removing comments).
- If fewer than N TODO lines remain, only those are run. When the count is
  zero, the delegator exits with a friendly message.

## Logs and where to look

- Front-end logs (controller): `experiments-runner/logs/<timestamp>/`
  - 01-instantiate.log, 02-prepare.log, 03-delegate.log, 04-collect.log
- Remote logs (machine): `~/experiments_node/on-machine/logs/`
  - One pair per job: `job_<idx>.out` and `job_<idx>.err`, plus optional `parallel.log` if GNU parallel is used

## Exit codes (summary)

- experiments-controller.sh: 0 success; 2 on invalid args, dependencies, or
  config; propagates non-zero from phases unless `--continue-on-error`
- machine-instantiator/automatic-machine-start.sh: 2 (not implemented yet)
- machine-instantiator/manual-machine-start.sh: 1 missing env/SSH key; 2 SSH connectivity failure
- project-preparation/prepare-remote-structure.sh: 2 on invalid args/missing tools; non-zero on remote failures
- node-setup/install-dependencies.sh: 2 on invalid args; non-zero if package manager fails
- node-setup/write-env.sh: 2 on invalid args or missing jq
- experiments-delegator/on-fe/experiments-delegator.sh: 2 on invalid args; non-zero on remote failures
- experiments-delegator/on-machine/run-batch.sh: 1 if any job reported errors; 2 on invalid args
- experiments-collector/on-machine/csnn_collection.sh: 2 on invalid args/paths

## Troubleshooting

- jq not found
  - Install on FE: apt: `sudo apt-get install -y jq`, yum: `sudo yum install -y jq`, dnf: `sudo dnf install -y jq`.
- SSH cannot connect
  - Verify `G5K_USER/G5K_HOST/G5K_SSH_KEY`, permissions on the key (chmod 600),
    and that the host is reachable from the FE.
- Permission denied writing env
  - `write-env.sh` prefers `/etc/profile.d` if passwordless sudo is available; otherwise falls back to `~/.profile`.
-- Packages fail to install
  - Dependency installation is no longer driven by config. Ensure your image
    contains the needed packages or run `install-dependencies.sh` manually.
- No jobs selected (empty TODO)
  - Inspect your params file and `*_tracker.txt`; remove or edit the tracker to reschedule lines deliberately.
- Parallel execution not installed
  - If GNU parallel is missing, the runner uses a background-jobs fallback honoring `--parallel N`.
- Where did my results go?
  - Raw per-job outputs live in `~/experiments_node/on-machine/logs/` and any
    `*.txt` your executable writes under the results path.
  - The `csnn_collection.sh` merges `*.txt` into `collected_results.txt`
    under the configured FE path on the machine;
    use `scp` to copy it back to the FE as needed.

## Per-project params folders

You can organize parameter lists per project inside the repo under
`experiments-runner/params/` using one folder per project. Each project
contains its params file (one params line per experiment). The delegator
tracker file is created next to that params file.

Params path resolution rules (Option A behavior):

- The config value `running_experiments.on_fe.to_do_parameters_list_path` may
  be either an absolute path or a repo-relative path.
- If the value starts with `/` it is treated as an absolute path and used
  verbatim.
- If the value is relative, the controller resolves it under a base
  directory `PARAMS_BASE` which defaults to `experiments-runner/params` in
  the repo. You can override by exporting `PARAMS_BASE` in your environment
  before running the controller:

```bash
export PARAMS_BASE=/home/youruser/SwiftDeploy-G5K/experiments-runner/params
./experiments-runner/experiments-controller.sh --config csnn-faces.json
```

This preserves configs that already contain absolute paths (like
`csnn-faces.json`) while allowing shorthand relative project paths for
others (e.g. `project-a/a.txt`).

## Collected results base

The controller now supports a repo-local base directory for collected
results on the frontend. If your config's `experiments_collection.path_to_save_experiment_results_on_fe`
is an absolute path it will be used as-is. If you put a project name (or
relative path) there, the controller will resolve it under
`experiments-runner/collected/` by default. You can override the base with
`COLLECTED_BASE` env var.

Example:

```json
"experiments_collection": {
  "collection_strategy": "csnn_collection.sh",
  "path_to_save_experiment_results_on_fe": "csnn-ckplus",
  "path_to_saved_experiment_results_on_machine": "/root/csnn-build/result"
}
```

This will write collected outputs to `experiments-runner/collected/csnn-ckplus/collected_results.txt`.

Example layout:

```text
experiments-runner/params/
  project-a/
    a.txt            # params for project A
    a_tracker.txt    # created by delegator (ignored by git)
  project-b/
    b.txt
    b_tracker.txt
```

How to use:

- Put your params file at the absolute path your FE will have after you
  clone the repo on the frontend (e.g. `/home/feuser/SwiftDeploy-G5K/experiments-runner/params/project-a/a.txt`).
- Set `running_experiments.on_fe.to_do_parameters_list_path` in the config
  to that absolute path. The delegator will create `${params_file%.txt}_tracker.txt`
  next to the params file to keep track of completed lines.

Note: `.gitignore` already ignores `experiments-runner/params/**/*_tracker.txt`
so trackers won't be committed.

## Common commands

Run the full workflow with default logging:

```bash
./experiments-runner/experiments-controller.sh --config csnn-faces.json
```

Enable verbose (debug) logging for troubleshooting:

```bash
./experiments-runner/experiments-controller.sh --config csnn-faces.json --verbose
```

Tail logs from the last run:

```bash
tail -n +1 -F experiments-runner/logs/last-run/*.log
```

## Notes

- All scripts use strict Bash mode and provide `--help`.
- The controller hardcodes the configs directory and accepts only a filename (not a path).
- Re-running phases is idempotent where possible (create-if-missing, skip-if-present).
