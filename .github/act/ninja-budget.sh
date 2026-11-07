#!/usr/bin/env bash
set -euo pipefail
if [[ -x /opt/agw-host-compiler/bin/make ]]; then
    export MAKE=/opt/agw-host-compiler/bin/make
    export PATH="/opt/agw-host-compiler/bin:$PATH"
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
        slots=${AGW_HEAVY_LOCK_DIR:-/cache/heavy}
        mkdir -p "$slots"
        while :; do
            for slot in 0 1; do
                exec 9> "$slots/llvm-$slot.lock"
                if flock -n 9; then exec "$real" -j4 "${args[@]}"; fi
                exec 9>&-
            done
            sleep 1
        done
        ;;
esac
case "${MAKEFLAGS:-}" in
    *--jobserver-auth=fifo:*) exec "$real" "${args[@]}" ;;
esac
exec "$real" -j"${ACT_KERNEL_TOOLS_JOBS:-8}" "${args[@]}"
