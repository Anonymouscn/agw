#!/usr/bin/env bash
set -euo pipefail
if [[ -x /opt/agw-host-compiler/bin/make ]]; then
    export MAKE=/opt/agw-host-compiler/bin/make
fi
real=${AGW_NINJA_REAL:-/prebuilt_tools/staging_dir/host/bin/ninja}
args=()
while (( $# )); do
    case "$1" in
        -j) shift; (( $# )) || exit 2; shift ;;
        -j[0-9]*) shift ;;
        *) args+=("$1"); shift ;;
    esac
done
case "$PWD" in
    *llvm*|*rust*)
        # Each container already has an independent memory/CPU cap.
        # A global semaphore starves unrelated architectures of work.
        jobs=${AGW_HEAVY_JOBS:-8}
        [[ $jobs =~ ^[1-9][0-9]*$ ]] || exit 2
        # Bound simultaneous heavy graphs inside one container, not globally.
        exec 9> "${AGW_HEAVY_LOCAL_LOCK:-/tmp/agw-heavy-ninja.lock}"
        flock 9
        exec "$real" -j"$jobs" "${args[@]}"
        ;;
esac
case "${MAKEFLAGS:-}" in
    *--jobserver-auth=fifo:*) exec "$real" "${args[@]}" ;;
esac
exec "$real" -j"${ACT_KERNEL_TOOLS_JOBS:-8}" "${args[@]}"
