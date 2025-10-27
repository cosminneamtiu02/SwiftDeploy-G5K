# Lookup Rules Examples (Reference Only)

<!-- markdownlint-disable MD013 -->

This file lists example rule labels you can copy into the `lookup_rules` array
of your `experiments_collection` block.
Each rule is a single-key JSON object: `{ "label": "glob" }`.
Globs are standard shell patterns evaluated **non-recursively** inside each
`look_into` directory. They do not perform directory traversal unless you
explicitly add wildcards containing `/` (not recommended here).

## General Guidance

- Keep labels short and descriptive.
- Avoid overlapping globs unless you intentionally want the same file matched
  by multiple rules (duplicates are still only copied once per transfer
  procedure).
- Use only filename-level patterns (no recursion): e.g. `*.txt`, `run_*.log`, `metrics_??.csv`.
- If you need to distinguish artifacts by run ID, incorporate that into the glob (e.g. `exp123_*.json`).

## Core Categories

| Label            | Glob Pattern          | Purpose |
|------------------|-----------------------|---------|
| txt              | *.txt                 | Generic text outputs |
| logs             | *.log                 | Application / framework logs |
| csv              | *.csv                 | Tabular metrics/records |
| tsv              | *.tsv                 | Tab-separated variants |
| json             | *.json                | Structured reports or metadata |
| jsonl            | *.jsonl               | Line-delimited JSON streams |
| yaml             | *.yml                 | YAML short form |
| yaml_long        | *.yaml                | YAML long form |
| conf             | *.conf                | Config snapshots |
| ini              | *.ini                 | INI format configs |
| mk               | Makefile              | Build scripts |
| md               | *.md                  | Documentation artifacts |
| html             | *.html                | Generated HTML reports |
| xml              | *.xml                 | XML outputs |
| pdf              | *.pdf                 | Exported documents |
| images_png       | *.png                 | PNG figures / plots |
| images_jpg       | *.jpg                 | JPEG figures / photos |
| images_jpeg      | *.jpeg                | JPEG variant |
| images_svg       | *.svg                 | Vector plots |
| gifs             | *.gif                 | Animated / static GIFs |
| archives_zip     | *.zip                 | Zipped artifacts |
| archives_tar     | *.tar                 | Tar archives |
| archives_tgz     | *.tar.gz              | Compressed tars |
| archives_tzst    | *.tar.zst             | ZSTD compressed tars |
| pickle           | *.pkl                 | Python pickle objects |
| model_pt         | *.pt                  | PyTorch model weights |
| model_onnx       | *.onnx                | ONNX exported models |
| model_ckpt       | *.ckpt                | Generic checkpoint files |
| npy              | *.npy                 | Numpy arrays |
| npz              | *.npz                 | Numpy compressed bundles |
| parquet          | *.parquet             | Columnar data |
| feather          | *.feather             | Arrow Feather data |
| metrics_txt      | metrics_*.txt         | Metrics families in text form |
| metrics_json     | metrics_*.json        | Metrics families in JSON form |
| summary_txt      | summary_*.txt         | Summaries |
| summary_json     | summary_*.json        | Summaries in JSON |
| results_json     | results_*.json        | Result sets |
| results_txt      | results_*.txt         | Result sets text |
| run_logs         | run_*.log             | Per-run log naming convention |
| stderr_logs      | *stderr*.log          | Captured stderr logs |
| stdout_logs      | *stdout*.log          | Captured stdout logs |
| perf_profiles    | perf_*.json           | Performance profiles |
| traces           | trace_*.json          | Trace exports |
| stats_csv        | stats_*.csv           | Statistical summaries |
| confusion        | *confusion*.csv       | Confusion matrices |
| heatmaps         | *heatmap*.png         | Heatmap plots |
| roc_curves       | *roc*.png             | ROC curve images |
| pr_curves        | *pr*.png              | Precision-recall curve images |

## Example Snippet for Config

```jsonc
"lookup_rules": [
  { "txt": "*.txt" },
  { "logs": "*.log" },
  { "metrics_json": "metrics_*.json" },
  { "results_json": "results_*.json" },
  { "images_png": "*.png" }
]
```

Use only the labels you actually need. This file is illustrative; it is **not** auto-loaded by the controller.

<!-- markdownlint-enable MD013 -->
