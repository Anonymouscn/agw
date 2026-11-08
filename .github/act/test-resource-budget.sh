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
declare -A active=()
sleep 30 &
live_pid=$!
trap 'kill "$live_pid" 2>/dev/null || true' EXIT
active[$live_pid]=live
reap_one() { reaped=$1; unset 'active[$1]'; }
if regression_reap_ready; then echo 'Reaped a running child' >&2; exit 1; fi
active[99999999]=finished
regression_reap_ready
[[ $reaped = 99999999 && ${#active[@]} = 1 ]]
kill -0 "$live_pid"
echo 'PASS: admission polling does not wait for live jobs; reaps only a completed PID'
