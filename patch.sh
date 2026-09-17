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


# Fetch the current simple-obfs archive and keep its mirror hash in sync.
# The archive hash belongs to the generated source tarball, not the Git commit.
update_simple_obfs_hash() {
    local repo_abs="${ROOT}/feeds/helloworld"
    local pkg_makefile="${repo_abs}/simple-obfs/Makefile"
    local patch_abs="${PATCH_DIR}/001-simple-obfs-fix-mirror-hash.patch"
    local pkg_name pkg_version archive current_hash new_hash

    echo
    info "simple-obfs: update PKG_MIRROR_HASH from current source archive"
    info "Repository : ${repo_abs}"
    info "Patch      : ${patch_abs}"

    if [[ ! -f "${pkg_makefile}" ]]; then
        err "simple-obfs Makefile does not exist: ${pkg_makefile}"
        FAILED=$((FAILED + 1))
        return 1
    fi

    pkg_name="$(sed -n 's/^PKG_NAME:=//p' "${pkg_makefile}")"
    pkg_version="$(sed -n 's/^PKG_VERSION:=//p' "${pkg_makefile}")"
    archive="${ROOT}/dl/${pkg_name}-${pkg_version}.tar.xz"

    info "Downloading current ${pkg_name}-${pkg_version}.tar.xz with hash verification disabled"
    if ! make -s -C "${ROOT}" package/feeds/helloworld/simple-obfs/download PKG_MIRROR_HASH=skip >"/tmp/simple-obfs-dynamic-download.log" 2>&1; then
        err "Unable to download current simple-obfs source archive. See /tmp/simple-obfs-dynamic-download.log"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if [[ ! -f "${archive}" ]]; then
        err "Downloaded archive not found: ${archive}"
        FAILED=$((FAILED + 1))
        return 1
    fi

    current_hash="$(sed -n 's/^PKG_MIRROR_HASH:=//p' "${pkg_makefile}")"
    new_hash="$(sha256sum "${archive}" | awk '{print $1}')"

    if [[ "${current_hash}" == "${new_hash}" ]]; then
        ok "PKG_MIRROR_HASH is current: ${new_hash}"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    sed -i -E "s|^PKG_MIRROR_HASH:=.*$|PKG_MIRROR_HASH:=${new_hash}|" "${pkg_makefile}"

    # Keep the patch as an audit/replay artifact, based on the feed's current HEAD.
    git -C "${repo_abs}" diff --no-ext-diff -- simple-obfs/Makefile >"${patch_abs}"
    if [[ ! -s "${patch_abs}" ]]; then
        err "Hash changed but no Git diff was generated for simple-obfs"
        FAILED=$((FAILED + 1))
        return 1
    fi

    ok "Updated PKG_MIRROR_HASH: ${current_hash} -> ${new_hash}"
    APPLIED=$((APPLIED + 1))
    return 0
}


#

# Synchronize perf settings semantically so stale patch context cannot fail.
update_perf_makefile() {
    local makefile="${ROOT}/package/devel/perf/Makefile"
    local patch_abs="${PATCH_DIR}/002-perf-zstd-no-llvm.patch"
    local before after
    echo
    info "perf: synchronize dependency and linker settings"
    info "Repository : ${ROOT}"
    info "Patch      : ${patch_abs}"
    if [[ ! -f "${makefile}" ]]; then
        err "perf Makefile does not exist: ${makefile}"
        FAILED=$((FAILED + 1))
        return 1
    fi
    before="$(sha256sum "${makefile}" | awk '{print $1}')"
    python3 - "${makefile}" <<'PY'
import re, sys
from pathlib import Path
p=Path(sys.argv[1])
s=p.read_text()
if not re.search(r"(?m)^  DEPENDS:=.*\+libzstd(?:\s|$)", s):
    s,n=re.subn(r"(?m)^  DEPENDS:= \+libelf \+libdw ", "  DEPENDS:= +libelf +libdw +libzstd ", s, count=1)
    if n != 1: raise SystemExit("cannot locate perf DEPENDS line")
if "TARGET_LDFLAGS += $(INTL_LDFLAGS) -fuse-ld=bfd" not in s:
    s,n=re.subn(r"(?m)^TARGET_LDFLAGS += \$\(INTL_LDFLAGS\)$", "TARGET_LDFLAGS += $(INTL_LDFLAGS) -fuse-ld=bfd", s, count=1)
    if n == 0:
        a="HOST_CFLAGS += -I$(LINUX_DIR)/tools/include\n"
        if a not in s: raise SystemExit("cannot locate perf linker flag anchor")
        s=s.replace(a, a+"\nTARGET_LDFLAGS += $(INTL_LDFLAGS) -fuse-ld=bfd\n", 1)
if not re.search(r"(?m)^\s*NO_LIBLLVM=1\s*\\\\$", s):
    s,n=re.subn(r"(?m)^(\s*NO_LIBPERL=1\s*\\\\\n)", r"\1\tNO_LIBLLVM=1 \\\n", s, count=1)
    if n != 1: raise SystemExit("cannot locate perf MAKE_FLAGS insertion point")
if not re.search(r"(?m)^\s*NO_RUST=1\s*\\\\$", s):
    s,n=re.subn(r"(?m)^(\s*NO_LIBLLVM=1\s*\\\\\n)", r"\1\tNO_RUST=1 \\\n", s, count=1)
    if n != 1: raise SystemExit("cannot locate perf LLVM flag insertion point")
s=re.sub(r"(?m)^\s*NO_LIBZSTD=1\s*\\\\\n", "", s)
p.write_text(s)
PY
    after="$(sha256sum "${makefile}" | awk '{print $1}')"
    git -C "${ROOT}" diff --no-ext-diff -- package/devel/perf/Makefile > "${patch_abs}"
    if [[ ! -s "${patch_abs}" ]]; then
        err "Generated perf patch is empty: ${patch_abs}"
        FAILED=$((FAILED + 1))
        return 1
    fi
    printf '%s perf Makefile synchronized; patch regenerated: %s\n' "$(date -u +%FT%TZ)" "${patch_abs}" >> /tmp/openwrt-patch-changes.log
    if [[ "${before}" == "${after}" ]]; then
        ok "Already synchronized; refreshed patch: perf"
        SKIPPED=$((SKIPPED + 1))
    else
        ok "Synchronized and regenerated patch: perf"
        APPLIED=$((APPLIED + 1))
    fi
}

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
update_simple_obfs_hash || true


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
update_perf_makefile || true


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


# --------------------------------------------------------------------
# 006. kernel 7.2: fix WMI and i915 module paths
# --------------------------------------------------------------------
apply_git_patch \
    "." \
    "006-kernel72-wmi-module-path.patch" \
    "kernel 7.2: fix WMI and i915 module paths" || true

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
