#!/usr/bin/env bash
set -euo pipefail
cd /workspace/openwrt
export PATH="$PWD/staging_dir/host/bin:$PWD/staging_dir/hostpkg/bin:$PATH"
export GN_HOST_CC=/opt/agw-host-compiler/bin/cc
export GN_HOST_CXX=/opt/agw-host-compiler/bin/cxx
export GN_HOST_LDFLAGS=-Wl,-rpath=/opt/agw-host-compiler/lib
export CARGO_BUILD_JOBS=4 CMAKE_BUILD_PARALLEL_LEVEL=8
record=/results/rust-fast
mkdir -p "$record"
trap 'code=$?; printf "%s\n" "$code" > "$record/exit"' EXIT
oom_count() { awk '$1 == "oom_kill" {print $2}' /sys/fs/cgroup/memory.events; }
for jobs in 8 4; do
    before=$(oom_count)
    code=0
    printf '%s START jobs=%s oom_kill=%s\n' "$(date -u +%FT%TZ)" "$jobs" "$before" >> "$record/progress.log"
    /opt/agw-host-compiler/bin/make --jobserver-style=fifo \
        package/feeds/packages/rust/host/compile -j"$jobs" V=s BUILD_LOG=1 \
        RUST_BUILD_JOBS="$jobs" HOST_CMAKE_JOBS=8 \
        > "$record/jobs-$jobs.log" 2>&1 || code=$?
    after=$(oom_count)
    printf '%s END jobs=%s code=%s oom_kill=%s\n' "$(date -u +%FT%TZ)" "$jobs" "$code" "$after" >> "$record/progress.log"
    if (( code == 0 )); then exit 0; fi
    if (( jobs == 4 || after <= before )); then exit "$code"; fi
done
