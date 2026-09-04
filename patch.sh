#!/usr/bin/env bash
set -Eeuo pipefail

#
# OpenWrt local patch manager
#
# Expected layout:
#
# /data/src/openwrt/
# ├── patch.sh
# ├── local-patches/
# │   ├── 001-simple-obfs-fix-mirror-hash.patch
# │   ├── 002-perf-zstd-no-llvm.patch
# │   ├── 003-inotify-tools-fix-fsnotify-symlink.patch
# │   └── 004-xdp-tools-use-bfd.patch
# ├── feeds/
# │   ├── helloworld/
# │   └── packages/
# └── package/
#

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}"
PATCH_DIR="${ROOT}/local-patches"

FAILED=0
APPLIED=0
SKIPPED=0

info() {
    printf '\033[1;34m[INFO]\033[0m %s\n' "$*"
}

ok() {
    printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*"
}

err() {
    printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2
}

#
# apply_git_patch <repo> <patch> <description>
#
# repo:
#   "."                -> OpenWrt main repository
#   "feeds/packages"   -> packages feed repository
#   "feeds/helloworld" -> helloworld feed repository
#
apply_git_patch() {
    local repo="$1"
    local patch="$2"
    local desc="$3"

    local repo_abs
    local patch_abs="${PATCH_DIR}/${patch}"

    if [[ "${repo}" == "." ]]; then
        repo_abs="${ROOT}"
    else
        repo_abs="${ROOT}/${repo}"
    fi

    echo
    info "${desc}"
    info "Repository : ${repo_abs}"
    info "Patch      : ${patch_abs}"

    #
    # Check repository directory
    #
    if [[ ! -d "${repo_abs}" ]]; then
        err "Repository does not exist: ${repo_abs}"
        FAILED=$((FAILED + 1))
        return 1
    fi

    #
    # Check Git repository
    #
    if ! git -C "${repo_abs}" rev-parse \
        --is-inside-work-tree >/dev/null 2>&1
    then
        err "Not a Git repository: ${repo_abs}"
        FAILED=$((FAILED + 1))
        return 1
    fi

    #
    # Check patch file
    #
    if [[ ! -f "${patch_abs}" ]]; then
        err "Patch does not exist: ${patch_abs}"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if [[ ! -s "${patch_abs}" ]]; then
        err "Patch is empty: ${patch_abs}"
        FAILED=$((FAILED + 1))
        return 1
    fi

    #
    # Case 1:
    # Reverse check succeeds -> patch already applied.
    #
    if git -C "${repo_abs}" apply \
        --reverse \
        --check \
        --whitespace=nowarn \
        "${patch_abs}" >/dev/null 2>&1
    then
        ok "Already applied, skipping: ${desc}"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    #
    # Case 2:
    # Forward check succeeds -> apply normally.
    #
    if git -C "${repo_abs}" apply \
        --check \
        --whitespace=nowarn \
        "${patch_abs}" >/dev/null 2>&1
    then
        info "Patch not applied yet; applying..."

        if git -C "${repo_abs}" apply \
            --whitespace=nowarn \
            "${patch_abs}"
        then
            ok "Applied: ${desc}"
            APPLIED=$((APPLIED + 1))
            return 0
        fi

        err "Unexpected failure while applying: ${desc}"
        FAILED=$((FAILED + 1))
        return 1
    fi

    #
    # Case 3:
    # Source differs from original patch context.
    # Try 3-way merge.
    #
    warn "Patch does not cleanly match current source."
    warn "Attempting 3-way merge..."

    if git -C "${repo_abs}" apply \
        --3way \
        --whitespace=nowarn \
        "${patch_abs}"
    then
        ok "Applied using 3-way merge: ${desc}"
        APPLIED=$((APPLIED + 1))
        return 0
    fi

    #
    # Failed
    #
    err "Unable to apply patch: ${desc}"
    err "Current source differs from both original and patched state."
    err "Manual review is required."

    FAILED=$((FAILED + 1))
    return 1
}


#
# Header
#
echo
printf '%s\n' "============================================================"
printf '%s\n' " OpenWrt Local Patch Manager"
printf '%s\n' "============================================================"

info "OpenWrt root: ${ROOT}"
info "Patch dir   : ${PATCH_DIR}"


#
# 001 simple-obfs
#
# Repository:
#   feeds/helloworld
#
# Modification:
#   Fix PKG_MIRROR_HASH
#
apply_git_patch \
    "feeds/helloworld" \
    "001-simple-obfs-fix-mirror-hash.patch" \
    "simple-obfs: update PKG_MIRROR_HASH" || true


#
# 002 perf
#
# Repository:
#   OpenWrt main tree
#
# Modification:
#   Add libzstd dependency
#   Remove NO_LIBZSTD
#   Disable LLVM linkage
#
apply_git_patch \
    "." \
    "002-perf-zstd-no-llvm.patch" \
    "perf: enable libzstd dependency and disable LLVM linkage" || true


#
# 003 inotify-tools
#
# Repository:
#   feeds/packages
#
# Modification:
#   Make fsnotify symlink creation idempotent
#
apply_git_patch \
    "feeds/packages" \
    "003-inotify-tools-fix-fsnotify-symlink.patch" \
    "inotify-tools: make fsnotify symlink installation idempotent" || true


#
# 004 xdp-tools
#
# Repository:
#   OpenWrt main tree
#
# Modification:
#   Remove -fuse-ld=mold
#   Force -fuse-ld=bfd
#
# Reason:
#   mold does not support --format=binary / -b binary,
#   which libxdp uses for xdp-dispatcher.embed.o.
#
apply_git_patch \
    "." \
    "004-xdp-tools-use-bfd.patch" \
    "xdp-tools: force bfd linker for binary embedding" || true

# --------------------------------------------------------------------
# 005. speedtest-go: limit Go package build target
# Prevent example/naive from being built and packaged as "naive",
# which conflicts with naiveproxy.
# --------------------------------------------------------------------
apply_git_patch \
    "feeds/packages" \
    "005-speedtest-go-limit-build-target.patch" \
    "speedtest-go: limit Go package build target" || true

#
# Summary
#
echo
printf '%s\n' "============================================================"
printf ' Applied : %d\n' "${APPLIED}"
printf ' Skipped : %d\n' "${SKIPPED}"
printf ' Failed  : %d\n' "${FAILED}"
printf '%s\n' "============================================================"

if (( FAILED > 0 )); then
    err "One or more local patches could not be applied."
    exit 1
fi

ok "All local patches are consistent."
exit 0
