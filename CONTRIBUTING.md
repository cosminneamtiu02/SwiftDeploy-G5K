# Contributing Guide

Thanks for helping improve **SwiftDeploy-G5K**! This document summarises how to get ready, what the project expects, and
how to propose changes without breaking the automation pipeline.

---

## 🛠️ Getting Set Up

```bash
git clone https://github.com/cosminneamtiu02/SwiftDeploy-G5K.git
cd SwiftDeploy-G5K

# Install the pre-commit runner (pick your favourite package manager)
pipx install pre-commit        # recommended

# or: pip install pre-commit

pre-commit install            # install the git hook
pre-commit run --all-files    # optional sanity check
```

The hooks format Markdown/YAML, run `shellcheck` + `shfmt`, and guard against common git mistakes (merge conflicts,
oversized files, mixed line endings, etc.).

---

## ✍️ Making Changes

- **Scripts** should follow the existing style: `#!/usr/bin/env bash`, `set -euo pipefail`, helper functions under
 `runtime/common/`, and logging helpers from `logging.sh`.
- **Configuration** (JSON/YAML) must stay machine-editable: keep keys sorted, prefer comments in adjacent Markdown.
- **Documentation**: keep sentences short, prefer task-oriented steps, and cross-link files with relative paths.
- **Commit messages**: favour the conventional `type: summary` style when possible (`feat:`, `fix:`, `docs:`...).

Before committing, always run:

```bash
pre-commit run --all-files
```

If hooks auto-fix a file, stage the changes and run again until everything passes.

---

## 🔬 Validating Your Change

- For environment creator tweaks: test against a deployment reservation when feasible and paste the relevant command in
 your PR description.
- For experiments runner updates: run a dry-run (`--verbose`) or a small parameter batch and attach the last few log
 lines proving success.
- When touching docs or configs only, the pre-commit suite is usually sufficient—but mention that in the PR.

---

## 🧾 Opening Pull Requests

- Complete the PR template checklist so reviewers know which validations were performed.
- Link related issues (e.g. `Closes #42`).
- Keep diffs focused; if you need to reformat unrelated files, do it in a dedicated commit.
- Expect reviewers to request one green pipeline run (`pre-commit.ci`) before merging.

---

## 🐞 Filing Issues

- Use the provided templates so triage can happen quickly.
- For bug reports include: configuration JSON, parameter snippet, Grid'5000 site, relevant log excerpts.
- For feature requests specify whether the change affects the environment creator, experiments runner, or documentation.

---

## 🙋 Need Help?

- Read `.pre-commit-config.yaml` to understand the enforced checks.
- Join the LinkedIn contact listed in the repository if you need maintainer assistance.
- Otherwise, open an issue and describe the problem plus the context (front-end vs. node, targeted command, etc.).

Happy hacking! 🚀
