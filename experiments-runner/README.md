# Experiments Runner (Grid'5000)

This subproject automates Grid'5000 experiment workflows:
1) Machine instantiation (manual for now)
2) Project preparation (remote structure, env, packages)
3) Experiment delegation (parallel, tracked, live logs)
4) Results collection

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

```
experiments-controller.sh (orchestrator)
	├─ machine-instantiator/
	│    ├─ manual-machine-start.sh (validate SSH to target)  
	│    └─ automatic-machine-start.sh (stub: exits 2)
	├─ project-preparation/
	│    ├─ prepare-remote-structure.sh (create ~/experiments_node/*, upload on-machine scripts)
	│    └─ node-setup/
	│         ├─ write-env.sh (persist env vars)
	│         └─ install-dependencies.sh (apt/yum/dnf)
	├─ experiments-delegator/
	│    ├─ on-fe/experiments-delegator.sh (select params, upload commands, stream logs)
	│    ├─ on-fe/utils-params-tracker.sh (tracker management)
	│    └─ on-machine/run-batch.sh (parallel exec; GNU parallel or fallback)
	└─ experiments-collector/
			 └─ on-machine/csnn_collection.sh (concat *.txt → collected_results.txt)
```

Remote layout on the target machine (created under the user’s home):

```
~/experiments_node/
	on-machine/
		executables/   # optional helper binaries/scripts
		results/       # experiment outputs
		logs/          # per-job logs (job_N.out/err)
		collection/    # collection strategies (e.g., csnn_collection.sh)
		bootstrap/     # commands.pending, setup helpers
```

## Prerequisites

- Local (Front-end): bash 4+, ssh, scp, jq
- Remote (Target node): bash; optionally GNU parallel (fallback uses background jobs)
- Grid’5000 access and a reachable allocation/host

Environment expected for remote operations:

```
export G5K_USER=<user>
export G5K_HOST=<node.your-site.grid5000.fr>
export G5K_SSH_KEY=~/.ssh/id_rsa
```

Quick connectivity check:

```
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$G5K_SSH_KEY" "$G5K_USER@$G5K_HOST" true
```

## Quick start

1) Prepare a config JSON in `experiments-configurations/` (copy `_TEMPLATE.json` → `my-exp.json` or use `csnn-faces.json`).
2) Export environment variables `G5K_USER`, `G5K_HOST`, `G5K_SSH_KEY`.
3) Dry-run all phases (no side effects):

```
./experiments-runner/experiments-controller.sh --config csnn-faces.json --dry-run --verbose
```

Run specific phases (comma-separated):

```
./experiments-runner/experiments-controller.sh --config my-exp.json --phases prepare,delegate
```

Disable live log streaming (still writes to files):

```
./experiments-runner/experiments-controller.sh --config my-exp.json --no-live-logs
```

Force manual instantiation script (default is manual unless config says otherwise):

```
./experiments-runner/experiments-controller.sh --config my-exp.json --manual
```

Logs are written to `experiments-runner/logs/<timestamp>/` and symlinked as `experiments-runner/logs/last-run`.

## Controller CLI

```
./experiments-runner/experiments-controller.sh --config <FILENAME.json> [options]

Options:
	-c, --config <filename>     Filename under experiments-configurations/ (required)
	-p, --phases <list>         instantiate,prepare,delegate,collect (default: all)
			--dry-run               Print commands without executing
			--verbose               More debug output
			--continue-on-error     Do not stop after a failed phase
			--manual                Force manual instantiation script
			--log-dir <dir>         Custom logs directory (default: logs/<ts>)
			--no-color              Disable colored logs
			--no-live-logs          Do not stream logs live (still write to files)
	-h,   --help                Show help
				--version             Print version
```

## Configuration schema

The controller resolves the config by filename inside `experiments-runner/experiments-configurations/`.

Important fields (see `_TEMPLATE.json`):

- `machine_setup`
	- `is_machine_instantiator_manual` (boolean). If absent but `is_machine_instantiator_automatic` exists, it is inverted with a warning.
	- `os_distribution_type` (int): 1=Debian/apt, 2=RHEL7/yum, 3=RHEL7+/dnf
	- `list_of_needed_libraries` (string): path to a packages file on the machine (will be uploaded to remote /tmp and installed)
	- `env_variables_list` (array of single-key objects): persisted via `write-env.sh`
- `running_experiments.on_fe`
	- `to_do_parameters_list_path` (string): absolute path on FE with parameters (one per line)
- `running_experiments.on_machine`
	- `execute_command` (string): command to prefix to each params line
	- `full_path_to_executable` (string): absolute working directory or binary path on the machine
- `running_experiments.number_of_experiments_to_run_in_parallel_on_machine` (int)
- `running_experiments.experiments_collection` (object; may be empty)
	- Example keys for built-in strategy:
		- `collection_strategy`: "csnn_collection.sh"
		- `path_to_saved_experiment_results_on_machine`: directory containing *.txt results
		- `path_to_save_experiment_results_on_fe`: output directory for the combined file

Tip: Start from `_TEMPLATE.json` and replace absolute paths and values.

## Phase details

- instantiate
	- Runs `manual-machine-start.sh` (validates SSH) or `automatic-machine-start.sh` (stub; exits 2).
- prepare
	- Creates the remote tree under `~/experiments_node/on-machine/` and uploads `run-batch.sh` and collection scripts.
	- Persists env vars with `write-env.sh` and installs packages via `install-dependencies.sh` using the selected package manager.
- delegate
	- `on-fe/experiments-delegator.sh` selects up to N TODO lines from the params file using a tracker `*_tracker.txt` (same folder).
	- Uploads a `commands.pending` file to the remote bootstrap folder and calls `on-machine/run-batch.sh` with `--parallel N`.
	- Streams remote logs from `~/experiments_node/on-machine/logs/` (use `--no-stream` to disable).
- collect
	- Default `csnn_collection.sh` concatenates all `*.txt` under the machine path into `collected_results.txt` inside the FE path.
	- Note: By default, this runs on the machine; pull results to your FE if needed via `scp`.

## Delegation & tracker behavior

- The tracker file is `${params_file%.txt}_tracker.txt` next to your params file.
- TODO lines = params minus tracker (exact string match after trimming and removing comments).
- If fewer than N TODO lines remain, only those are run (including 0, in which case the delegator exits with a friendly message).

## Logs and where to look

- Front-end logs (controller): `experiments-runner/logs/<timestamp>/`
	- 01-instantiate.log, 02-prepare.log, 03-delegate.log, 04-collect.log
- Remote logs (machine): `~/experiments_node/on-machine/logs/`
	- One pair per job: `job_<idx>.out` and `job_<idx>.err`, plus optional `parallel.log` if GNU parallel is used

## Exit codes (summary)

- experiments-controller.sh: 0 success; 2 on invalid args/dependencies/config; propagates non-zero from phases unless `--continue-on-error`
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
	- Verify `G5K_USER/G5K_HOST/G5K_SSH_KEY`, permissions on the key (chmod 600), and that the host is reachable from the FE.
- Permission denied writing env
	- `write-env.sh` prefers `/etc/profile.d` if passwordless sudo is available; otherwise falls back to `~/.profile`.
- Packages fail to install
	- Confirm `os_distribution_type` matches the remote OS and `list_of_needed_libraries` is accessible; check remote `/tmp/install-deps_*.sh` logs.
- No jobs selected (empty TODO)
	- Inspect your params file and `*_tracker.txt`; remove or edit the tracker to reschedule lines deliberately.
- Parallel execution not installed
	- If GNU parallel is missing, the runner uses a background-jobs fallback honoring `--parallel N`.
- Where did my results go?
	- Raw per-job outputs live in `~/experiments_node/on-machine/logs/` and any `*.txt` your executable writes under the results path.
	- The `csnn_collection.sh` merges `*.txt` into `collected_results.txt` under the configured FE path on the machine; scp it back to FE as needed.

## Examples

Dry-run all phases with verbose logs:

```
./experiments-runner/experiments-controller.sh --config csnn-faces.json --dry-run --verbose
```

Prepare remote structure only:

```
./experiments-runner/experiments-controller.sh --config my-exp.json --phases prepare
```

Delegate with no live streaming and continue after failures:

```
./experiments-runner/experiments-controller.sh --config my-exp.json --phases delegate --no-live-logs --continue-on-error
```

Tail logs from the last run:

```
tail -n +1 -F experiments-runner/logs/last-run/*.log
```

## Notes

- All scripts use strict Bash mode and provide `--help`.
- The controller hardcodes the configs directory and accepts only a filename (not a path).
- Re-running phases is idempotent where possible (create-if-missing, skip-if-present).
