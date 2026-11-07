#!/usr/bin/env bash
set -euo pipefail
source "${1:?resource budget script}"
nproc() { echo 72; }
systemctl() { [[ ${FAKE_RUNNING:-1} = 1 ]]; }
total_memory=$((92 * 1048576))
memory_bytes=$((12 * 1073741824))
jobs=11
export ACT_KERNEL_RESERVATIONS='x86:24:12 mips:12:12'
regression_resources_fit 4
if regression_resources_fit 5; then echo 'Overcommit allowed' >&2; exit 1; fi
FAKE_RUNNING=0
regression_resources_fit 6
if regression_resources_fit 7; then echo 'Overcommit allowed' >&2; exit 1; fi
echo 'PASS: four matrix lanes with two bounded repairs, six after repairs, reject overcommit'
