# SwiftDeploy-G5K

[![pre-commit](https://img.shields.io/badge/pre--commit-enabled-brightgreen?logo=pre-commit&logoColor=white)](https://github.com/pre-commit/pre-commit)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

SwiftDeploy-G5K is an automation toolkit for [Grid'5000](https://www.grid5000.fr/) experiments. It packages two
complementary pieces:

- **Environment creator** – provisions a node, applies your bootstrap script, and captures a reusable image
  (`.tar.zst` + `.yaml`).
- **Experiments runner** – orchestrates large experiment batches end-to-end (selection → provisioning → preparation →
  delegation → collection) with robust logging and artifact harvesting.

Together they let you iterate quickly on machine-learning workloads that need reproducible images and repeatable
execution pipelines.

---

## 📦 Components at a Glance

- **Environment creator** (`./env-creator/frontend-controller.sh <config.conf>`): builds a Grid'5000-compatible
  environment from a config (`env-creator/configs/*.conf`) and a node bootstrap script
  (`env-creator/node-build-scripts/`). The flow provisions a temporary node, executes your setup script, then saves the
  compressed image plus its YAML descriptor under `~/envs/`.
- **Experiments runner** (`./experiments-runner/experiments-controller.sh --config <file>`): schedules parameterised
  jobs on an allocated node, manages done trackers on the front-end, streams logs, and copies results back according to
  declarative transfer rules defined in the configuration JSON.

Key technologies: strict Bash scripting, `jq` for JSON parsing, `kadeploy3` for image deployment, OpenSSH for
connectivity, and Grid'5000 conventions for environment management.

---

## 🧭 Typical Workflow

1. **Capture an environment** on a deploy reservation using the environment creator.
2. **Describe your experiment batch** in `experiments-runner/experiments-configurations/` and add parameter files under
   `experiments-runner/params/`.
3. **Run the controller** from a front-end. It will:
   - Select the next chunk of pending parameter lines (`phase-selection`).
   - Provision or redeploy the target node with your saved image (`phase-provisioning`).
   - Prepare remote folders, env vars, and helper scripts (`phase-preparation`).
   - Delegate the work in parallel respecting your concurrency caps (`phase-delegation`).
   - Collect logs/artifacts back to the front-end using glob-based rules (`phase-collection`).
4. Inspect logs under `experiments-runner/logs/` and collected artifacts under `~/public/<base_path>/` on the front-end.
     If the run aborts, the controller restores any lines it appended to `done.txt` so unfinished parameters remain queued.

All scripts are idempotent where possible so you can safely retry failed phases.

---

## ✅ Prerequisites

- Grid'5000 account with SSH key registered.
- `kadeploy3`, `tgz-g5k`, and standard GNU utilities on the front-end.
- `jq`, `base64`, and OpenSSH available locally and remotely.
- Optional: GNU Parallel on the worker node for faster delegation (falls back to background jobs otherwise).

---

## 🚀 Quick Start

### 1. Build & Capture an Environment

```bash
# Reserve a deployment node (pick the queue/cluster you need)
oarsub -I -t deploy -q default

# From inside the repo checkout
chmod +x env-creator/frontend-controller.sh
./env-creator/frontend-controller.sh csnn-ckplus-3d-CN.conf
```

The script deploys the base OS, pushes your setup script, collects the resulting `~/envs/img/<NAME>.tar.zst` and
`~/envs/img-files/<NAME>.yaml`, and cleans up temporary markers.

### 2. Run a Batch of Experiments

```bash
# Reserve a deployment node (pick the queue/cluster you need)
oarsub -I -t deploy -q default
./experiments-runner/experiments-controller.sh --config csnn-faces.json --verbose
# looks for `csnn-faces.json` in `experiments-configurations/` and `experiments-configurations/implementations/`
```

The controller validates that `G5K_SSH_KEY` points to an existing private key and falls back to `~/.ssh/id_rsa` when the
variable is unset.

The controller streams logs into `experiments-runner/logs/<timestamp>/` while the remote node receives a structured
layout under `~/experiments_node/on-machine/`.

On failure or interruption, the controller automatically rolls back the latest batch selection so the next run resumes
exactly where it left off.

---

## 🧾 Configuration Cheat Sheet

- `running_experiments.on_fe.to_do_parameters_list_path` – absolute or repo-relative path to the parameter file (one
  experiment per line). Relative entries resolve under `experiments-runner/params/`. Each selected batch is tracked in
  a sibling `done.txt`; failed runs remove their entries so unfinished work stays queued.
- `running_experiments.on_machine.full_path_to_executable` – remote working directory or binary path; must exist in the
  captured image.
- `running_experiments.on_machine.execute_command` – command invoked for each parameter line (receives the line as the
  last argument).
- `running_experiments.number_of_experiments_to_run_in_parallel_on_machine` – controls concurrency for the delegation
  phase.
- `running_experiments.experiments_collection` – optional object describing how to glob files on the node and where to
  copy them back on the front-end. Relative `base_path` values land under `~/public/<base_path>/`.
- `machine_setup.image_to_use` – YAML descriptor produced by the environment creator.
- `machine_setup.env_variables_list` – list of environment variables to persist on the remote machine before execution.

See `experiments-runner/experiments-configurations/TEMPLATE.json` for a fully annotated example and
`experiments-runner/experiments-configurations/implementations/` for concrete workloads.

### Failure handling & logs

- `done.txt` rollback keeps the parameter queue consistent across reruns.
- Each phase writes a dedicated log under `experiments-runner/logs/<timestamp>/` alongside transient state files for
  troubleshooting.
- Artifact transfers report the exact files copied and capture diagnostics when nothing matches your patterns.

---

## 🗂️ Repository Layout

- `env-creator/` – scripts and configs used to build reusable Grid'5000 environments.
- `experiments-runner/` – multi-phase pipeline that schedules, runs, and gathers results for experiment batches.
- `.github/` – issue/PR templates and automation.
- `.tools/` – wrappers required by pre-commit hooks (e.g., `shfmt`).
- `.vscode/` – optional editor tasks.

---

## 🤝 Contributing

- Install hooks: `pipx install pre-commit` (or `pip install pre-commit`) then `pre-commit install`.
- Run the full suite before committing: `pre-commit run --all-files`.
- Please read the refreshed [Contributing Guide](./CONTRIBUTING.md) for coding standards, review expectations, and
  troubleshooting tips.

---

## 📄 License

Distributed under the [MIT License](./LICENSE).
