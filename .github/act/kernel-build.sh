#!/usr/bin/env bash
set -euo pipefail
record=${ACT_KERNEL_RECORD:-/results}
mkdir -p "$record"
jobs=${ACT_KERNEL_JOBS:-24}
tools_jobs=${ACT_KERNEL_TOOLS_JOBS:-8}
board=${ACT_KERNEL_TARGET:?}
subtarget=${ACT_KERNEL_SUBTARGET:?}
version=${ACT_KERNEL_VERSION:?}
release=${ACT_KERNEL_RELEASE:?}
testing=${ACT_KERNEL_TESTING:-0}
scope=${ACT_REGRESSION_SCOPE:-kernel}
feeds=${ACT_REGRESSION_FEEDS:-none}
[[ $scope = kernel || $scope = packages || $scope = firmware ]]
[[ $feeds = none || $feeds = locked ]]
export AGW_SCAN_JOBS="${ACT_KERNEL_SCAN_JOBS:-$jobs}"
[[ $AGW_SCAN_JOBS =~ ^[1-9][0-9]*$ ]]
if [[ $scope != kernel ]]; then
    export CARGO_BUILD_JOBS=2 RUST_BUILD_JOBS=2 GOMAXPROCS="$jobs" CMAKE_BUILD_PARALLEL_LEVEL="$tools_jobs"
fi
phase=setup
make_bin=make
make_style=()
if [[ -x /opt/agw-host-compiler/bin/make ]]; then
    make_bin=/opt/agw-host-compiler/bin/make
    make_style=(--jobserver-style=fifo)
    mkdir -p /tmp/agw-make-bin
    ln -sf "$make_bin" /tmp/agw-make-bin/make
    ln -sf "$make_bin" /tmp/agw-make-bin/gmake
    export MAKE="$make_bin" PATH="/tmp/agw-make-bin:$PATH"
    export GN_HOST_CC=/opt/agw-host-compiler/bin/cc
    export GN_HOST_CXX=/opt/agw-host-compiler/bin/cxx
    export GN_HOST_LDFLAGS="-L/opt/agw-host-compiler/lib -Wl,-rpath=/opt/agw-host-compiler/lib"
fi
cp .github/act/ninja-budget.sh /tmp/agw-host-ninja
chmod +x /tmp/agw-host-ninja
cp /tmp/agw-host-ninja "$record/ninja-wrapper.txt"
[[ $jobs =~ ^[1-9][0-9]*$ ]]
[[ $tools_jobs =~ ^[1-9][0-9]*$ ]]
[[ $board =~ ^[a-zA-Z0-9_]+$ && $subtarget =~ ^[a-zA-Z0-9_]+$ ]]
validate_kernel_release() {
    local release_file actual_release
    release_file=$(find build_dir -path "*/linux-$release/include/config/kernel.release" -print -quit)
    test -n "$release_file" || return 1
    actual_release=$(cat "$release_file") || return 1
    [[ $actual_release = "$release" || $actual_release = "$release-"* ]] || return 1
    printf '%s\n' "$actual_release" > "$record/kernel.release"
}
finish() {
    result=$?
    set +e
    if [[ $scope != kernel && -f .config && -f tmp/.packageinfo && -x staging_dir/host/bin/apk ]]; then
        image_args=()
        if [[ $scope = firmware ]]; then image_args=(--images); fi
        python3 .github/act/package-coverage.py --output "$record/coverage" \
            --build-exit-file "$record/packages.exit" --run-exit "$result" "${image_args[@]}" > "$record/coverage-audit.log" 2>&1
    fi
    staging_dir/host/bin/ccache --show-stats > "$record/ccache-stats.txt" 2>&1
    staging_dir/host/bin/ccache --print-log-stats --format=json > "$record/ccache-job-stats.json" 2>/dev/null
    printf 'BUILD_EXIT=%s\nPHASE=%s\n' "$result" "$phase" > "$record/result.txt"
    test ! -f .config || cp -p .config "$record/config.final"
    config=$(find build_dir -path "*/linux-$release/.config" -print -quit 2>/dev/null)
    test -z "$config" || cp -p "$config" "$record/kernel.config"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
source_times() {
    python3 - "$@" <<'PY'
import json, os, pathlib, subprocess, sys
mode, manifest = sys.argv[1:]
if mode == 'capture':
    paths = subprocess.check_output(['git', 'ls-files', '-z']).split(b'\0')
    data = {os.fsdecode(p): os.lstat(p).st_mtime_ns for p in paths if p and os.path.lexists(p)}
    pathlib.Path(manifest).write_text(json.dumps(data))
elif mode == 'restore':
    for name, stamp in json.loads(pathlib.Path(manifest).read_text()).items():
        path = pathlib.PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts:
            raise ValueError('Unsafe cache timestamp path')
        if os.path.lexists(name):
            os.utime(name, ns=(os.lstat(name).st_atime_ns, stamp), follow_symlinks=False)
else:
    raise ValueError('Unsupported timestamp operation')
PY
}
git rev-parse HEAD > "$record/source.commit"
git diff --binary > "$record/source.diff"
uname -a > "$record/host.txt"
run_make() {
    phase=$1
    shift
    local started=$SECONDS
    echo "::group::$phase"
    if "$make_bin" "${make_style[@]}" "$@" BUILD_LOG=1 V=s > "$record/$phase.log" 2>&1; then
        printf '0\n' > "$record/$phase.exit"
        printf '%s\t%s\n' "$phase" "$((SECONDS - started))" >> "$record/timings.tsv"
        tail -6 "$record/$phase.log"
    else
        result=$?
        printf '%s\n' "$result" > "$record/$phase.exit"
        printf '%s\t%s\n' "$phase" "$((SECONDS - started))" >> "$record/timings.tsv"
        tail -60 "$record/$phase.log"
        ret=$result bash .github/workflows/scripts/show_build_failures.sh logs 10 || true
        echo '::endgroup::'
        return "$result"
    fi
    echo '::endgroup::'
}
if [[ ${ACT_KERNEL_STAGE:-full} = full ]]; then
    phase=host-tools-cache
    tools_cache=/cache/host-tools/${ACT_KERNEL_TOOLS_KEY:?}.tar
    # Host tools are shared across targets built with the same source and host ABI.
    # tools/install still fills in tools selected only by the target configuration.
    common_key=$( { git rev-parse HEAD; git diff HEAD --binary -- tools include; \
        sha256sum .github/act/kernel-build.sh /opt/agw-host-compiler/packages.tsv; \
        uname -m; cat /etc/os-release; ldd --version 2>&1; } | sha256sum | cut -d" " -f1)
    common_cache=/cache/host-tools/common-$common_key.tar
    printf "%s\n" "$common_key" > "$record/common-host-tools-cache.key"
    cache_valid=0
    exec 7>/cache/host-tools/cache.lock
    flock -s 7
    # Restore into this container's private layer. Never share writable tools.
    if [[ ${ACT_WORKSPACE_REUSED:-0} = 1 ]]; then
        echo REUSED_WORKSPACE > "$record/host-tools-cache.txt"
    elif test -f "$tools_cache" || test -f "$common_cache"; then
        cache_file=$tools_cache
        cache_kind=HIT
        if ! test -f "$cache_file"; then cache_file=$common_cache; cache_kind=COMMON_HIT; fi
        tar -xf "$cache_file" -C /prebuilt_tools
        if test -f /prebuilt_tools/staging_dir/host/agw-source-times.json; then
            source_times restore /prebuilt_tools/staging_dir/host/agw-source-times.json
            cache_valid=1
            echo "$cache_kind" > "$record/host-tools-cache.txt"
        else
            echo MISS > "$record/host-tools-cache.txt"
        fi
    else
        echo MISS > "$record/host-tools-cache.txt"
    fi
    flock -u 7
    mkdir -p staging_dir build_dir
    test -L staging_dir/host || ln -s /prebuilt_tools/staging_dir/host staging_dir/host
    test -L build_dir/host || ln -s /prebuilt_tools/build_dir/host build_dir/host
    test -L dl || ln -s /cache/dl dl
    ./scripts/ext-tools.sh --refresh
    if [[ $feeds = locked ]]; then
        phase=feeds
        if [[ ${ACT_WORKSPACE_REUSED:-0} = 1 ]]; then
            python3 .github/act/feed-lock.py validate --lock .github/regression/feeds.lock.json > "$record/feeds.log" 2>&1
        else
            python3 .github/act/feed-lock.py restore --lock .github/regression/feeds.lock.json > "$record/feeds.log" 2>&1
        fi
        ./scripts/feeds update -i >> "$record/feeds.log" 2>&1
        ./scripts/feeds install -a >> "$record/feeds.log" 2>&1
        cp .github/regression/feeds.lock.json "$record/feeds.lock.json"
    fi
    toolchains=(/external-toolchain/*/toolchain-*)
    test -d "${toolchains[0]}"
    printf '%s\n' 'CONFIG_ALL_KMODS=y' 'CONFIG_KERNEL_WERROR=y' 'CONFIG_DEVEL=y' > .config
    if [[ $scope != kernel ]]; then
        printf '%s\n' 'CONFIG_ALL=y' 'CONFIG_AUTOREMOVE=y' >> .config
    fi
    if [[ $scope = firmware ]]; then
        printf '%s\n' 'CONFIG_TARGET_MULTI_PROFILE=y' 'CONFIG_TARGET_PER_DEVICE_ROOTFS=y' \
            'CONFIG_TARGET_ALL_PROFILES=y' 'CONFIG_JSON_OVERVIEW_IMAGE_INFO=y' >> .config
    fi
    printf '%s\n' 'CONFIG_CCACHE=y' 'CONFIG_CCACHE_DIR="/cache/ccache"' >> .config
    export CCACHE_DIR=/cache/ccache CCACHE_COMPILERCHECK=content
    export CCACHE_MAXSIZE=24G CCACHE_NAMESPACE="$board-$subtarget-$version"
    export CCACHE_STATSLOG="$record/ccache.statslog"
    if [[ $testing = 1 ]]; then printf 'CONFIG_TESTING_KERNEL=y\n' >> .config; fi
    ./scripts/ext-toolchain.sh --toolchain "${toolchains[0]}" --overwrite-config --config "$board/$subtarget"
    run_make defconfig defconfig
    if [[ $feeds = locked ]]; then
        phase=local-patches
        ./patch.sh > "$record/local-patches.log" 2>&1
        phase=configuration-refresh
        run_make defconfig defconfig
    fi
    if [[ $scope != kernel || $feeds = locked ]]; then
        phase=configuration-diagnostics
        python3 .github/act/check-config.py --log "$record/config-check.log"
    fi
    if grep -Eq '^CONFIG_PACKAGE_gn=[ym]$' .config; then
        phase=native-host-compiler
        host_cxx=/opt/agw-host-compiler
        test -f "$host_cxx/complete"
        "$host_cxx/bin/cxx" --version > "$record/host-cxx-version.txt"
        export GN_HOST_CC="$host_cxx/bin/cc" GN_HOST_CXX="$host_cxx/bin/cxx"
        export GN_HOST_LDFLAGS="-L$host_cxx/lib -Wl,-rpath=$host_cxx/lib"
    fi
    if [[ -x /opt/agw-host-compiler/bin/make ]]; then
        make_bin=/opt/agw-host-compiler/bin/make
        make_style=(--jobserver-style=fifo)
        export MAKE="$make_bin"
        "$make_bin" --version > "$record/make-version.txt"
    fi
    phase=configuration-validation
    grep -qx "CONFIG_TARGET_${board}_${subtarget}=y" .config
    grep -qx "CONFIG_LINUX_${version//./_}=y" .config
    grep -qx 'CONFIG_ALL_KMODS=y' .config
    grep -qx 'CONFIG_KERNEL_WERROR=y' .config
    ./scripts/ext-tools.sh --refresh
    cp -p .config "$record/config.all-kmods"
    grep -qx 'CONFIG_CCACHE=y' .config
    ./scripts/diffconfig.sh > "$record/diffconfig"
    grep -E '^CONFIG_PACKAGE_kmod-.*=[ym]$' .config > "$record/selected-kmods.txt"
    test -s "$record/selected-kmods.txt"
    # Keep NINJA an executable path: Meson does not accept arguments in it.
    # Ninja shares Make 4.4 FIFO tokens; bound it on older pipe jobservers.
    printf '#!/bin/sh\ncase "$MAKEFLAGS" in *--jobserver-auth=fifo:*) exec /prebuilt_tools/staging_dir/host/bin/ninja "$@" ;; esac\nexec /prebuilt_tools/staging_dir/host/bin/ninja -j%s "$@"\n' "$tools_jobs" > /tmp/agw-host-ninja
    cp .github/act/ninja-budget.sh /tmp/agw-host-ninja
    chmod +x /tmp/agw-host-ninja
    cp /tmp/agw-host-ninja "$record/ninja-wrapper.txt"
    run_make tools tools/install -j"$tools_jobs" NINJA=/tmp/agw-host-ninja HOST_CMAKE_JOBS="$tools_jobs"
    phase=host-tools-cache-publish
    if (( cache_valid == 0 )) && (( $(df -Pk /cache/host-tools | awk 'NR==2 {print $4}') > 62914560 )); then
        staging_dir/host/bin/ccache --version > "$record/ccache-version.txt"
        source_times capture staging_dir/host/agw-source-times.json
        cache_tmp=$tools_cache.$$.tmp
        tar -cf "$cache_tmp" -C /prebuilt_tools staging_dir build_dir
        flock -x 7
        mv "$cache_tmp" "$tools_cache"
        if ! test -f "$common_cache"; then ln "$tools_cache" "$common_cache"; fi
        # Bound snapshots to 16 GiB; extraction holds the shared lock above.
        while (( $(du -sk /cache/host-tools | cut -f1) > 16777216 )); do
            oldest=$(find /cache/host-tools -maxdepth 1 -name '*.tar' ! -name 'common-*.tar' -printf '%T@ %p\n' | sort -n | head -1 | cut -d' ' -f2-)
            test -n "$oldest" || break
            rm -f -- "$oldest"
        done
        flock -u 7
    fi
    run_make toolchain toolchain/install -j"$jobs"
    run_make clean target/linux/clean
    run_make kernel target/compile -j"$jobs"
    phase=kernel-version-validation
    validate_kernel_release
elif [[ ${ACT_KERNEL_STAGE:-full} = kmods ]]; then
    test -f .config
    run_make defconfig defconfig
elif [[ ${ACT_KERNEL_STAGE:-full} = packages ]]; then
    test "${ACT_WORKSPACE_REUSED:-0}" = 1
    [[ $scope != kernel ]]
    test -f .config
    test -f tmp/.packageinfo
    validate_kernel_release
    # Reconfigure failed host tools that cached the old compiler/make paths.
    while IFS= read -r stamp; do
        if test ! -f "$(dirname "$stamp")/.built"; then
            printf '%s\n' "$stamp" >> "$record/reconfigured-host-stamps.txt"
            rm -f -- "$stamp"
        fi
    done < <(find build_dir/hostpkg -maxdepth 3 -type f \
        \( -path '*/gn-*/.configured*' -o -path '*/perl-*/.configured*' -o -path '*/otp_src_*/.configured*' \))
else
    echo 'Unsupported ACT_KERNEL_STAGE' >&2
    exit 2
fi
if [[ $scope != kernel ]]; then
    run_make packages package/compile -k -j"$jobs" IGNORE_ERRORS= NINJA=/tmp/agw-host-ninja HOST_CMAKE_JOBS="$tools_jobs"
    phase=package-coverage
    python3 .github/act/package-coverage.py --output "$record/coverage" \
        --build-exit-file "$record/packages.exit" --require-complete
    if [[ $scope = firmware ]]; then
        run_make firmware world -k -j"$jobs" IGNORE_ERRORS= NINJA=/tmp/agw-host-ninja HOST_CMAKE_JOBS="$tools_jobs"
        phase=image-coverage
        python3 .github/act/package-coverage.py --output "$record/coverage" \
            --build-exit-file "$record/packages.exit" --require-complete --images
    fi
else
run_make kmods package/linux/compile -k -j"$jobs"
phase=external-kmods-detection
python3 .github/act/external-kmods.py > "$record/external-kmod-targets.txt"
mapfile -t external_targets < "$record/external-kmod-targets.txt"
if (( ${#external_targets[@]} )); then
    # Defconfig/prerequisites already passed above. Enter one internal make
    # graph: the top-level wrapper otherwise rebuilds shared deps per goal.
    run_make external-kmods -r -f .github/act/external-kmods.mk -k -j"$jobs" "${external_targets[@]}"
else
    printf 'No selected out-of-tree kmod packages.\n' > "$record/external-kmods.log"
    printf '0\n' > "$record/external-kmods.exit"
fi
fi
phase=artifacts
output=bin/targets/$board/$subtarget
find "$output/packages" -name 'kmod-*.apk' -type f -print | sort > "$record/apk-list.txt"
test -s "$record/apk-list.txt"
tar -C "$output" -cf "$record/kmods.tar" packages
phase=complete
echo "Regression scope=$scope feeds=$feeds passed for kernel $release on $board/$subtarget."
