#!/usr/bin/env bash
set -euo pipefail
record=${ACT_KERNEL_RECORD:-/results}
mkdir -p "$record"
jobs=${ACT_KERNEL_JOBS:-32}
board=${ACT_KERNEL_TARGET:?}
subtarget=${ACT_KERNEL_SUBTARGET:?}
version=${ACT_KERNEL_VERSION:?}
release=${ACT_KERNEL_RELEASE:?}
testing=${ACT_KERNEL_TESTING:-0}
phase=setup
[[ $jobs =~ ^[1-9][0-9]*$ ]]
[[ $board =~ ^[a-zA-Z0-9_]+$ && $subtarget =~ ^[a-zA-Z0-9_]+$ ]]
finish() {
    result=$?
    set +e
    printf 'BUILD_EXIT=%s\nPHASE=%s\n' "$result" "$phase" > "$record/result.txt"
    test ! -f .config || cp -p .config "$record/config.final"
    config=$(find build_dir -path "*/linux-$release/.config" -print -quit 2>/dev/null)
    test -z "$config" || cp -p "$config" "$record/kernel.config"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git rev-parse HEAD > "$record/source.commit"
git diff --binary > "$record/source.diff"
uname -a > "$record/host.txt"
run_make() {
    phase=$1
    shift
    echo "::group::$phase"
    if make "$@" BUILD_LOG=1 V=s > "$record/$phase.log" 2>&1; then
        printf '0\n' > "$record/$phase.exit"
        tail -6 "$record/$phase.log"
    else
        result=$?
        printf '%s\n' "$result" > "$record/$phase.exit"
        tail -60 "$record/$phase.log"
        ret=$result bash .github/workflows/scripts/show_build_failures.sh logs 10 || true
        echo '::endgroup::'
        return "$result"
    fi
    echo '::endgroup::'
}
if [[ ${ACT_KERNEL_STAGE:-full} = full ]]; then
    mkdir -p staging_dir build_dir
    ln -s /prebuilt_tools/staging_dir/host staging_dir/host
    ln -s /prebuilt_tools/build_dir/host build_dir/host
    ln -s /cache/dl dl
    ./scripts/ext-tools.sh --refresh
    toolchains=(/external-toolchain/*/toolchain-*)
    test -d "${toolchains[0]}"
    printf '%s\n' 'CONFIG_ALL_KMODS=y' 'CONFIG_KERNEL_WERROR=y' 'CONFIG_DEVEL=y' > .config
    if [[ $testing = 1 ]]; then printf 'CONFIG_TESTING_KERNEL=y\n' >> .config; fi
    ./scripts/ext-toolchain.sh --toolchain "${toolchains[0]}" --overwrite-config --config "$board/$subtarget"
    run_make defconfig defconfig
    phase=configuration-validation
    grep -qx "CONFIG_TARGET_${board}_${subtarget}=y" .config
    grep -qx "CONFIG_LINUX_${version//./_}=y" .config
    grep -qx 'CONFIG_ALL_KMODS=y' .config
    grep -qx 'CONFIG_KERNEL_WERROR=y' .config
    cp -p .config "$record/config.all-kmods"
    ./scripts/diffconfig.sh > "$record/diffconfig"
    grep -E '^CONFIG_PACKAGE_kmod-.*=[ym]$' .config > "$record/selected-kmods.txt"
    test -s "$record/selected-kmods.txt"
    run_make tools tools/install -j"$jobs"
    run_make toolchain toolchain/install -j"$jobs"
    run_make clean target/linux/clean
    run_make kernel target/compile -j"$jobs"
    phase=kernel-version-validation
    release_file=$(find build_dir -path "*/linux-$release/include/config/kernel.release" -print -quit)
    test -n "$release_file"
    actual_release=$(cat "$release_file")
    [[ $actual_release = "$release" || $actual_release = "$release-"* ]]
    printf '%s\n' "$actual_release" > "$record/kernel.release"
elif [[ ${ACT_KERNEL_STAGE:-full} = kmods ]]; then
    test -f .config
    run_make defconfig defconfig
else
    echo 'Unsupported ACT_KERNEL_STAGE' >&2
    exit 2
fi
run_make kmods package/linux/compile -k -j"$jobs"
phase=artifacts
output=bin/targets/$board/$subtarget
find "$output/packages" -name 'kmod-*.apk' -type f -print | sort > "$record/apk-list.txt"
test -s "$record/apk-list.txt"
tar -C "$output" -cf "$record/kmods.tar" packages
phase=complete
echo "Kernel $release and all kmod packages passed for $board/$subtarget."
