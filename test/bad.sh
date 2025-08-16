#!/usr/bin/env bash
set -euo pipefail
msg=hello
echo ${msg}
if [[ "${msg}" = "hello" ]]; then
echo ok
fi
