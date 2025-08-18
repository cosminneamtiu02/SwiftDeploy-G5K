# Contributing Guide

[![Shell Quality](https://github.com/cosminneamtiu02/grid5k-MLRW/actions/workflows/shell-quality.yml/badge.svg)](https://github.com/cosminneamtiu02/grid5k-MLRW/actions/workflows/shell-quality.yml)

[![pre-commit.ci status](https://img.shields.io/endpoint?url=https://badge.pre-commit.ci/https://github.com/cosminneamtiu02/grid5k-MLRW/main)](https://pre-commit.ci/)

Thanks for contributing! 🎉

This project enforces strict code quality standards using **pre-commit hooks** and **GitHub Actions**.
Following this guide will help you get set up and avoid CI failures.

## What is Pre-commit?

**Pre-commit** automatically runs quality checks on your code **before** each commit, ensuring:

- **Code formatting** is consistent (YAML, Markdown)
- **No trailing whitespace** or missing newlines
- **Shell scripts** are properly formatted and linted
- **YAML files** are valid (workflows, configs)
- **Markdown** follows style guidelines
- **No large files** or merge conflicts

If any check fails, the commit is blocked until you fix the issues. Many problems are **auto-fixed** for you!

---

## Local Setup

### 1) Clone the repository

```bash
git clone https://github.com/cosminneamtiu02/grid5k-MLRW.git
cd grid5k-MLRW
```

### 2) Install pre-commit (choose one)

```bash
# Using pip
pip install pre-commit

# Using pipx (recommended)
pipx install pre-commit

# Using homebrew (macOS)
brew install pre-commit

# Using apt (Ubuntu/Debian)
sudo apt install pre-commit
```

### 3) Enable pre-commit hooks

```bash
pre-commit install
```

### 4) Test the setup (optional but recommended)

```bash
pre-commit run --all-files
```

This will run all quality checks on your entire codebase and auto-fix many issues.

---

## Development Workflow

### 1) Make changes

Edit files as needed. Pre-commit will automatically check:

- **Markdown files** (`.md`) - formatting and style
- **YAML files** (`.yml`, `.yaml`) - syntax and formatting
- **Shell scripts** (`.sh`, `.bash`) - shellcheck linting and shfmt formatting
- **All files** - trailing whitespace, end-of-file newlines, large files

### 2) Commit your changes

```bash
git add .
git commit -m "your descriptive message"
```

**What happens during commit:**

- Pre-commit runs automatically
- Many issues are **auto-fixed** (formatting, whitespace, etc.)
- If auto-fixes are made, you'll need to stage and commit again
- If unfixable issues exist, commit is blocked until you fix them

### 3) Push and open a Pull Request

```bash
git push origin your-branch-name
```

### 4) CI runs automatically

- **pre-commit.ci**: Runs the same checks online
- **Shell Quality workflow**: Additional shell script validation
- All checks must pass before merging

### 5) Address any feedback

Fix issues raised by pre-commit, CI, or code reviewers, then push updates.

---

## Common Pre-commit Scenarios

### ✅ Everything works smoothly

```bash
git commit -m "Add new feature"
# Pre-commit runs, everything passes
# Commit succeeds
```

### 🔧 Auto-fixes applied

```bash
git commit -m "Update documentation"
# Pre-commit fixes formatting issues automatically
# You'll see: "files were modified by this hook"
git add .  # Stage the auto-fixes
git commit -m "Update documentation"  # Commit again
```

### ❌ Manual fixes needed

```bash
git commit -m "Add shell script"
# Pre-commit finds shellcheck errors
# Fix the reported issues in your files
git add .
git commit -m "Add shell script"  # Try again
```

### 🚀 Skip pre-commit (emergency only)

```bash
git commit -m "Urgent hotfix" --no-verify
# Only use in emergencies - CI will still catch issues
```

---

## Troubleshooting

### Pre-commit is too slow

```bash
# Run only on changed files (default behavior)
git commit -m "your message"

# Skip specific hooks if needed
SKIP=actionlint git commit -m "your message"
```

### Reset pre-commit environment

```bash
pre-commit clean
pre-commit install --install-hooks
```

### Update pre-commit hooks

```bash
pre-commit autoupdate
```

---

## Contribution Checklist

- [ ] I ran `pre-commit install` to set up hooks
- [ ] I tested my changes with `pre-commit run --all-files`
- [ ] All auto-fixes have been committed
- [ ] All pre-commit checks pass locally
- [ ] CI shows green checkmarks for all required checks

---

## Questions?

- Check the [pre-commit documentation](https://pre-commit.com/)
- Look at `.pre-commit-config.yaml` to see what checks are enabled
- Open an issue if you need help with setup
