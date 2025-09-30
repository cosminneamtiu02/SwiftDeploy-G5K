# Configuration Implementation Instructions

This guide explains how to fill in a config JSON for the Experiments Runner.
Use it alongside the example-only template at
`experiments-runner/experiments-configurations/_TEMPLATE.json`.

## Overview

The configuration controls four phases:

- instantiate: deploy the image to your reserved node
- prepare: create remote structure and upload required files
- delegate: run experiments in parallel on the node
- collect: (optional) gather results

The controller expects a JSON file inside `experiments-runner/experiments-configurations/`.

## Keys and how to fill them

### running_experiments.on_fe.to_do_parameters_list_path

- What: Path on the FE to a text file with one parameters line per experiment.
- Format: One experiment per line, comments allowed if your executable ignores them.
- Relative paths: Resolved under `experiments-runner/params/` (override via `PARAMS_BASE`).
- Examples:
  - `"csnn-ckplus/runs.txt"`
  - `"/absolute/path/to/my_runs.txt"`

### running_experiments.on_machine.execute_command

- What: Command prefix to execute on the node for each line from the parameters file.
- Tips:
  - If it’s relative like `./my_binary`, it will run inside `full_path_to_executable`.
  - If it’s absolute, make sure the path exists in your image.
- Examples:
  - `"./Video_3d_CK_Plus_face_single_elypse_experiment"`
  - `"python3 train.py"`

### running_experiments.on_machine.full_path_to_executable

- What: Absolute working directory on the node where commands are executed.
- Must exist after deploy (baked in the image or created during prepare).
- Examples:
  - `"/root/csnn-build"`
  - `"/home/user/project"`

### running_experiments.number_of_experiments_to_run_in_parallel_on_machine

- What: Concurrency level on the node (>= 1).
- Behavior: Uses GNU parallel if available; otherwise, a background-jobs fallback.
- Examples: `1`, `4`, `8`

### running_experiments.experiments_collection

- Optional: Omit or set `{}` to skip.
- Built-in example strategy `csnn_collection.sh`:
  - `collection_strategy`: Must be `"csnn_collection.sh"` for the built-in collector
  - `path_to_saved_experiment_results_on_machine`: Directory with `*.txt` to collect
  - `path_to_save_experiment_results_on_fe`: Target directory on FE for the combined file
- Example:

```json
{
  "collection_strategy": "csnn_collection.sh",
  "path_to_saved_experiment_results_on_machine": "/root/csnn-build/result",
  "path_to_save_experiment_results_on_fe": "csnn-ckplus"
}
```

### machine_setup.image_to_use

- What: The image YAML filename to deploy.
- Location: `experiments-runner/generated-yamls/`
- Example: `"env-csnn-st-with-dbs-image.yaml"`

### machine_setup.env_variables_list

- What: Environment variables to persist on the node.
- Format: Array of single-key objects.
- Example:

```json
[
  { "CK_PLUS_CSV_PATH": "/root/data_CK+/CK+_emotion.csv" },
  { "CK_PLUS_IMAGES_DIR": "/root/data_CK+" }
]
```

### machine_setup.is_machine_instantiator_manual

- Recommended: `true` unless you implemented an automatic flow for your image.

### machine_setup.os_distribution_type

- What: OS family used by your image.
- Values: `1` (Debian/apt), `2` (RHEL7/yum), `3` (RHEL7+/dnf)
- Example: `1`

## Example template

See `_TEMPLATE.json` for a ready-to-edit example using the CSNN setup.
Copy it to a new file, then substitute paths and values for your project.

## Tips and troubleshooting

- Relative FE paths resolve under `experiments-runner/` unless overridden via env vars.
- Absolute node paths must exist after deploy; bake them into the image or ensure the preparation phase creates them.
- Concurrency can exceed CPU cores; choose based on workload characteristics.
- If you don’t need collection, set `experiments_collection` to `{}`.
- Logs: controller writes to `experiments-runner/logs/<timestamp>/`; node logs under `~/experiments_node/on-machine/logs/`.
