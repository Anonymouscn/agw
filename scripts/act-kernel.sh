#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
act_bin=${ACT_BIN:-/data/act/bin/act}
if [[ ${1:-} = --list ]]; then
    exec "$act_bin" -C "$root" -W "$root/.github/act/kernel.yml" workflow_dispatch --list
fi
targets=("$@")
if [[ ${#targets[@]} = 0 ]]; then targets=(64 legacy); fi
declare -A seen=()
for target in "${targets[@]}"; do
    [[ $target = 64 || $target = legacy ]] || { echo 'Supported targets: 64 legacy' >&2; exit 2; }
    [[ ! ${seen[$target]:-} ]] || { echo 'Duplicate target' >&2; exit 2; }
    seen[$target]=1
done
command -v "$act_bin" >/dev/null
docker info >/dev/null
jobs=${ACT_KERNEL_JOBS:-32}
memory=${ACT_KERNEL_MEMORY:-40g}
[[ $jobs =~ ^[1-9][0-9]*$ ]]
[[ $memory =~ ^[1-9][0-9]*[gm]$ ]]
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
run_root=${ACT_KERNEL_RUN_ROOT:-/data/act/runs}/$run_id
log_root=${ACT_KERNEL_LOG_ROOT:-/var/log/agw-act}/$run_id
mkdir -p "$run_root" "$log_root"
sha256sum "$root/.config" > "$log_root/production-config.before.sha256"
run_target() {
    local target=$1 image workspace record result
    image=ghcr.io/openwrt/toolchain:x86-$target-latest
    workspace=$run_root/$target
    record=$log_root/$target
    mkdir -p "$workspace" "$record"
    docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image"
    image=$(docker image inspect "$image" --format '{{index .RepoDigests 0}}')
    printf '%s\n' "$image" > "$record/image.digest"
    git clone --local --quiet "$root" "$workspace/openwrt"
    git -C "$root" diff HEAD --binary > "$record/source.diff"
    if test -s "$record/source.diff"; then
        git -C "$workspace/openwrt" apply --binary "$record/source.diff"
    fi
    mkdir -p "$workspace/openwrt/.github/act"
    cp -a "$root/.github/act/." "$workspace/openwrt/.github/act/"
    sed -i "1s/Local Kernel CI/Local Kernel CI $run_id x86-$target/" "$workspace/openwrt/.github/act/kernel.yml"
    cp -a "$workspace/openwrt/.github/act" "$record/workflow"
    "$act_bin" --version > "$record/act.version"
    set +e
    "$act_bin" -C "$workspace/openwrt" -W "$workspace/openwrt/.github/act/kernel.yml" workflow_dispatch \
        --bind --pull=false --network bridge -P "ubuntu-latest=$image" --container-daemon-socket=- \
        --container-options "--cpus=$jobs --memory=$memory --volume=$record:/results --volume=$root/dl:/cache/dl" \
        --env "ACT_KERNEL_SUBTARGET=$target" --env "ACT_KERNEL_JOBS=$jobs" \
        2>&1 | tee "$record/act.log"
    result=${PIPESTATUS[0]}
    set -e
    printf 'ACT_EXIT=%s\n' "$result" > "$record/act-result.txt"
    return "$result"
}
pids=()
for target in "${targets[@]}"; do run_target "$target" & pids+=("$!"); done
result=0
for pid in "${pids[@]}"; do wait "$pid" || result=1; done
sha256sum -c "$log_root/production-config.before.sha256" || result=1
printf 'ACT_EXIT=%s\n' "$result" > "$log_root/result.txt"
echo "Workspaces: $run_root"
echo "Logs: $log_root"
exit "$result"
