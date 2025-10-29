# Experiments Runner (Grid'5000)

This subproject automates Grid'5000 experiment workflows:

1. Machine instantiation (manual for now)
2. Project preparation (remote structure, env, packages)
3. Experiment delegation (parallel, tracked, live logs)
4. Results collection

## Architecture overview

```text
experiments-controller.sh (front-end orchestrator)
 ├─ bin/
 │    ├─ common/
 │    │    ├─ environment.sh      # shared path + logging bootstrap
 │    │    ├─ logging.sh          # thin wrapper around liblog
 │    │    └─ collector.sh        # JSON parsing + validation helpers
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
  bootstrap/     # commands.pending, setup helpers

Collector remote tools are uploaded per run under `/tmp/swiftdeploy_pipeline_<user>_<pid>/`.
```

## Prerequisites

- Grid’5000 access and a reachable allocation/host.
- SSH private key available at `~/.ssh/id_rsa` (set `G5K_SSH_KEY` if you must use a different key).

## Quick start

1. Prepare a config JSON in `experiments-configurations/`.
  Copy `_TEMPLATE.json` to `my-exp.json` or start from `csnn-faces.json`.
2. Ensure your SSH private key exists at `~/.ssh/id_rsa`; export `G5K_SSH_KEY` only if you need a different key.
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
  - `to_do_parameters_list_path` (string): relative to `experiments-runner/params/`
    by default; accept an absolute path if the file lives elsewhere (one params
    line per experiment)
- `running_experiments.on_machine`
  - `execute_command` (string): command to prefix to each params line
  - `full_path_to_executable` (string): absolute working directory or binary path
    on the machine
- `running_experiments.number_of_experiments_to_run_in_parallel_on_machine` (int)
- `running_experiments.experiments_collection` (object; may be empty)
  - `base_path`: folder name resolving under `~/public/` on the FE, or an absolute path used verbatim.
  - `lookup_rules`: array of `{ "label": "glob" }` entries defining glob patterns.
  - `ftransfers`: array of transfer objects containing:
    - `look_into`: absolute directory on the node to scan.
    - `look_for`: array of rule labels to apply.
    - `transfer_to_subfolder_of_base_path`: destination subfolder created under the resolved base path.
  - Omit the object or set to `{}` to skip artifact collection entirely.

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
- Remote helpers live in `runtime/phases/phase-collection/remote-tools/` and are uploaded
  automatically per run inside the temporary bundle.

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

## Troubleshooting

- jq not found
  - Install on FE: apt: `sudo apt-get install -y jq`, yum: `sudo yum install -y jq`, dnf: `sudo dnf install -y jq`.
- SSH cannot connect
  - Ensure the target node is reachable from the FE and that your SSH key exists at
    `${G5K_SSH_KEY:-~/.ssh/id_rsa}` with proper permissions (e.g. `chmod 600`).
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
  - The collector pipeline copies artifacts into `~/public/<base_path>/<subfolder>`
    on the FE (or to your absolute `base_path` if you provided one).

## Per-project params folders

You can organize parameter lists per project inside the repo under
`experiments-runner/params/` using one folder per project. Each project
contains its params file (one params line per experiment). The delegator
tracker file is created next to that params file.

Params path resolution rules:

- `running_experiments.on_fe.to_do_parameters_list_path` accepts either an
  absolute path (used verbatim) or a path relative to
  `experiments-runner/params/` inside the repo.
  Relative examples such as `project-a/a.txt` automatically resolve to
  `experiments-runner/params/project-a/a.txt`.

## Collected results base

Provide `experiments_collection.base_path` in your configuration to control
where transfers land on the front-end:

- Absolute paths are used verbatim.
- Relative paths resolve under `~/public/` and keep the per-transfer subfolder.

By default the collector copies matched files to `~/public/<base_path>/<subfolder>`.
Give an absolute `base_path` if you want a different root.

Example:

```json
"experiments_collection": {
  "base_path": "csnn-ckplus",
  "lookup_rules": [
    { "txt": "*.txt" }
  ],
  "ftransfers": [
    {
      "look_into": "/root/csnn-build/result",
      "look_for": ["txt"],
      "transfer_to_subfolder_of_base_path": "results"
    }
  ]
}
```

This copies matched files under `~/public/csnn-ckplus/results/` on the FE.
If you provide an absolute `base_path`, it will be used as-is.

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

- Store params inside the repo (e.g. `experiments-runner/params/project-a/a.txt`).
- Set `running_experiments.on_fe.to_do_parameters_list_path` to a path
  relative to `experiments-runner/params/` or provide an absolute path if
  the file lives elsewhere. The delegator will create `${params_file%.txt}_tracker.txt`
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
