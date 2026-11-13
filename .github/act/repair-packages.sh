#!/usr/bin/env bash
set -euo pipefail
cd /workspace/openwrt
jobs=${REPAIR_JOBS:-24}
tools_jobs=${REPAIR_TOOLS_JOBS:-12}
[[ $jobs =~ ^[1-9][0-9]*$ && $tools_jobs =~ ^[1-9][0-9]*$ ]]
record=${REPAIR_RECORD:-/results/repairs-parallel}
mkdir -p "$record"
# One scheduler per worktree: package staging directories are shared.
exec 9> /tmp/agw-package-repair.lock
flock -n 9 || { echo 'Another repair queue is active' >&2; exit 2; }
host=/opt/agw-host-compiler
test -x "$host/bin/make"
export GN_HOST_CC="$host/bin/cc" GN_HOST_CXX="$host/bin/cxx"
export GN_HOST_LDFLAGS="-Wl,-rpath=$host/lib"
export CARGO_BUILD_JOBS=2 RUST_BUILD_JOBS=2
export GOMAXPROCS="$jobs" CMAKE_BUILD_PARALLEL_LEVEL="$tools_jobs"
ninja="$record/ninja"
printf '#!/bin/sh\ncase "$MAKEFLAGS" in *--jobserver-auth=fifo:*) exec /prebuilt_tools/staging_dir/host/bin/ninja "$@" ;; esac\nexec /prebuilt_tools/staging_dir/host/bin/ninja -j%s "$@"\n' "$tools_jobs" > "$ninja"
chmod +x "$ninja"
failed=0
for target in "$@"; do
    name=${target//\//_}
    printf '%s START %s jobs=%s tools=%s\n' "$(date -u +%FT%TZ)" "$target" "$jobs" "$tools_jobs" >> "$record/progress.log"
    code=0
    "$host/bin/make" --jobserver-style=fifo "$target" -j"$jobs" V=s BUILD_LOG=1 \
        NINJA="$ninja" HOST_CMAKE_JOBS="$tools_jobs" RUST_BUILD_JOBS=2 \
        > "$record/$name.log" 2>&1 || code=$?
    printf '%s\n' "$code" > "$record/$name.exit"
    printf '%s END %s %s\n' "$(date -u +%FT%TZ)" "$target" "$code" >> "$record/progress.log"
    if (( code != 0 )); then failed=1; fi
done
exit "$failed"
