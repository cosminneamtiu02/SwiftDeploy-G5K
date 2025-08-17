# Contributing

All changes go through Pull Requests.  
Merges are blocked unless **Shell gatekeeper (blocking)** passes.

## How to check before PR
1. Install tools:
   - `shellcheck` - apt install shellcheck
   - `shfmt` - snap install shfmt
2. Run locally:
   shellcheck -x -S style **/*.sh
   shfmt -i 2 -ci -d .
   # or auto-fix:
   shfmt -i 2 -ci -w .

## Pull Request rules
- Fix all shellcheck and shfmt errors.
- PR must pass **Shell gatekeeper (blocking)**.