# Contributing Guide

Thanks for contributing!
This project enforces strict shell script quality with pre-commit and GitHub Actions.
Following this guide will help you get set up and avoid CI failures.

---

## Local Setup

1) Clone the repository

    git clone https://github.com/cosminneamtiu02/grid5k-MLRW.git
    cd grid5k-MLRW

2) Install pre-commit (choose one)

    pip install pre-commit

    pipx install pre-commit

    brew install pre-commit

3) Enable pre-commit hooks

    pre-commit install

4) Run all checks manually (optional)

    pre-commit run --all-files

The commands above ensure ShellCheck and shfmt run locally on every commit.

---

## Development Workflow

1) Make changes
   - Edit or add shell scripts.
   - Commit normally. If hooks fail, fix issues and commit again.

    git commit -m "your message"

2) Push and open a Pull Request to `main`

    git push origin <your-branch-name>

3) CI runs automatically
   - Shell review (advisory): posts inline comments with reviewdog (non-blocking).
   - Shell gatekeeper (blocking): required check; must pass (syntax, shellcheck, shfmt).

4) Address feedback
   - Fix issues raised by pre-commit, reviewdog, or CI.
   - Push updates; CI re-runs.

5) Merge
   - When all required checks are green, the PR can be merged (per repository rules).

---

## PR Checklist

- [ ] I ran `pre-commit run --all-files` locally.
- [ ] All shell scripts are formatted (shfmt).
- [ ] All shell scripts pass lint (shellcheck).
- [ ] CI shows “Shell gatekeeper (blocking)” as passing.

---

## CI Status Badge

[![Shell Quality](https://github.com/cosminneamtiu02/grid5k-MLRW/actions/workflows/shell-quality.yml/badge.svg)](https://github.com/cosminneamtiu02/grid5k-MLRW/actions/workflows/shell-quality.yml)
