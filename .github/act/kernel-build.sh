#!/usr/bin/env bash
set -euo pipefail
record=${ACT_KERNEL_RECORD:-/results}
mkdir -p "$record"
jobs=${ACT_KERNEL_JOBS:-32}
subtarget=${ACT_KERNEL_SUBTARGET:?}
[[ $jobs =~ ^[1-9][0-9]*$ ]]
[[ $subtarget = 64 || $subtarget = legacy ]]
finish() {
    result=$?
    printf 'BUILD_EXIT=%s\n' "$result" > "$record/result.txt"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git rev-parse HEAD > "$record/source.commit"
git diff --binary > "$record/source.diff"
uname -a > "$record/host.txt"
run_make() {
    local phase=$1
    shift
    echo "::group::$phase"
    if make "$@" BUILD_LOG=1 V=s > "$record/$phase.log" 2>&1; then
        tail -8 "$record/$phase.log"
    else
        local result=$?
        tail -100 "$record/$phase.log"
        ret=$result bash .github/workflows/scripts/show_build_failures.sh logs 15 || true
        echo "::endgroup::"
        return "$result"
    fi
    echo "::endgroup::"
}
if [[ ${ACT_KERNEL_STAGE:-full} = full ]]; then
mkdir -p staging_dir build_dir
ln -s /prebuilt_tools/staging_dir/host staging_dir/host
ln -s /prebuilt_tools/build_dir/host build_dir/host
ln -s /cache/dl dl
scripts/ext-tools.sh --refresh
toolchains=(/external-toolchain/*/toolchain-*)
test -d "${toolchains[0]}"
printf '%s\n' 'CONFIG_ALL_KMODS=y' 'CONFIG_KERNEL_WERROR=y' 'CONFIG_DEVEL=y' > .config
./scripts/ext-toolchain.sh --toolchain "${toolchains[0]}" --overwrite-config --config "x86/$subtarget"
run_make defconfig defconfig
grep -qx "CONFIG_TARGET_x86_$subtarget=y" .config
grep -qx 'CONFIG_ALL_KMODS=y' .config
grep -qx 'CONFIG_KERNEL_WERROR=y' .config
cp -p .config "$record/config.all-kmods"
scripts/diffconfig.sh > "$record/diffconfig"
grep -E '^CONFIG_PACKAGE_kmod-.*=[ym]$' .config > "$record/selected-kmods.txt"
wc -l "$record/selected-kmods.txt"
test "$(wc -l < "$record/selected-kmods.txt")" -gt 500
run_make tools tools/install -j"$jobs"
run_make toolchain toolchain/install -j"$jobs"
run_make clean target/linux/clean
run_make kernel target/compile -j"$jobs"
elif [[ ${ACT_KERNEL_STAGE:-full} = kmods ]]; then
    test -f .config
    run_make defconfig defconfig
else
    echo 'Unsupported ACT_KERNEL_STAGE' >&2
    exit 2
fi
run_make kmods package/linux/compile -k -j"$jobs"
find "bin/targets/x86/$subtarget/packages" -name 'kmod-*.apk' -type f -print | sort > "$record/apk-list.txt"
for package in polynomial phy-airoha-en8811h dwmac-motorcomm crypto-rsa fs-nfs-common-rpcsec; do
    if ! grep -Eq "^CONFIG_PACKAGE_kmod-$package=[ym]$" .config; then
        continue
    fi
    archive=$(find "bin/targets/x86/$subtarget/packages" -maxdepth 1 -name "kmod-$package-*.apk" -print -quit)
    test -n "$archive"
    staging_dir/host/bin/apk adbdump "$archive" > "$record/kmod-$package.manifest"
done
echo 'All-kmod kernel build and package build passed.'
