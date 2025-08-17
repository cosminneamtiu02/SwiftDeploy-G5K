# grid5k-MLRW

[![Shell Quality](https://github.com/cosminneamtiu02/grid5k-MLRW/actions/workflows/shell-quality.yml/badge.svg)](https://github.com/cosminneamtiu02/grid5k-MLRW/actions/workflows/shell-quality.yml)

This repository provides an infrastructure for Grid'5000, supporting and accelerating multiple parallel and synchronous machine learning trainings. It also includes tools for building images and offers a standardized approach for collecting results on the platform.


## 🛠 Pre-commit hooks for Shell & Bash linting

This repository uses [pre-commit](https://pre-commit.com/) to run **ShellCheck** (best-practices) and **shfmt** (code formatting) automatically before each commit.

### Why?
- **Instant feedback** — catch shell/bash issues locally before pushing
- **Consistent formatting** — no more style debates; `shfmt` fixes it
- **Fewer CI failures** — matches the same checks run in GitHub Actions

### How to install

1. **Install pre-commit** (pick one):
   ```bash
   pip install pre-commit
   # or
   pipx install pre-commit
   # or (macOS with Homebrew)
   brew install pre-commit


### **Before a big PR please use:**

```bash
   pre-commit run --all-files
