#!/usr/bin/env bash
# libosdetect.sh — map os_distribution_type to package manager
set -Eeuo pipefail
IFS=$'\n\t'

os_map() {
  # $1: os_distribution_type (1=Debian/apt, 2=RHEL7/yum, 3=RHEL7+/dnf)
  case "$1" in
    1) echo "apt";;
    2) echo "yum";;
    3) echo "dnf";;
    *) echo "unknown"; return 1;;
  esac
}
