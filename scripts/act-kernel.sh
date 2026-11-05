#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
act_bin=${ACT_BIN:-/data/act/bin/act}
work_base=${ACT_KERNEL_RUN_ROOT:-/data/act/runs}
log_base=${ACT_KERNEL_LOG_ROOT:-/var/log/agw-act}
status_report() {
    local id=${1:-$(cat /data/act/latest-run)} key target version testing release state
    [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]
    local record=$log_base/$id
    printf 'TARGET\tKERNEL\tMODE\tSTATE\n'
    while IFS=$'\t' read -r key target version testing release; do
        [[ $key != key ]] || continue
        state=$(cat "$record/$key/state" 2>/dev/null || echo PENDING)
        printf '%s\t%s\t%s\t%s\n' "$target" "$release" "$testing" "$state"
    done < "$record/matrix.tsv"
}
resume_id=
case ${1:-} in
    --status) status_report "${2:-}"; exit ;;
    --list|--plan) exec bash "$root/.github/act/kernel-matrix.sh" "$root" ;;
    --all) shift ;;
    --resume) resume_id=${2:?batch id required}; shift 2 ;;
esac
selectors=("$@")
for i in "${!selectors[@]}"; do
    case ${selectors[$i]} in 64|legacy) selectors[$i]=x86/${selectors[$i]} ;; esac
done
jobs=${ACT_KERNEL_JOBS:-12}
memory=${ACT_KERNEL_MEMORY:-12g}
parallel=${ACT_KERNEL_PARALLEL:-6}
[[ $jobs =~ ^[1-9][0-9]*$ && $memory =~ ^[1-9][0-9]*[gm]$ ]]
[[ $parallel =~ ^[1-9][0-9]*$ ]]
if (( jobs * parallel > $(nproc) )); then
    echo 'Requested CPU budget exceeds available CPUs' >&2
    exit 2
fi
memory_bytes=${memory%?}
case ${memory: -1} in g) ((memory_bytes *= 1073741824)) ;; m) ((memory_bytes *= 1048576)) ;; esac
total_memory=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
if (( memory_bytes * parallel > total_memory * 1024 - 8 * 1073741824 )); then
    echo 'Requested memory budget must leave at least 8 GiB for the host' >&2
    exit 2
fi
command -v "$act_bin" >/dev/null
docker info >/dev/null
mkdir -p "$work_base" "$log_base"
exec 8>/data/act/kernel-queue.lock
flock -n 8 || { echo 'Another kernel regression queue is running' >&2; exit 2; }
run_id=${resume_id:-$(date -u +%Y%m%dT%H%M%SZ)-$$}
[[ $run_id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]
run_root=$work_base/$run_id
log_root=$log_base/$run_id
mkdir -p "$run_root" "$log_root"
if [[ -z $resume_id ]]; then
sha256sum "$root/.config" > "$log_root/production-config.before.sha256"
git clone --local --quiet "$root" "$run_root/source"
git -C "$root" diff HEAD --binary > "$log_root/source.diff"
if test -s "$log_root/source.diff"; then git -C "$run_root/source" apply --binary "$log_root/source.diff"; fi
mkdir -p "$run_root/source/.github/act"
cp -a "$root/.github/act/." "$run_root/source/.github/act/"
git -C "$run_root/source" rev-parse HEAD > "$log_root/source.commit"
bash "$run_root/source/.github/act/kernel-matrix.sh" "$run_root/source" > "$log_root/all-matrix.tsv" 2> "$log_root/matrix.log"
head -1 "$log_root/all-matrix.tsv" > "$log_root/matrix.tsv"
declare -A matched=()
while IFS=$'\t' read -r key target version testing release; do
    [[ $key != key ]] || continue
    select_row=0
    if [[ ${#selectors[@]} = 0 ]]; then select_row=1; fi
    for selector in "${selectors[@]}"; do
        if [[ $selector = "$target" || $selector = "$target@$version" ]]; then select_row=1; matched[$selector]=1; fi
    done
    if [[ $select_row = 1 ]]; then printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$target" "$version" "$testing" "$release" >> "$log_root/matrix.tsv"; fi
done < "$log_root/all-matrix.tsv"
for selector in "${selectors[@]}"; do
    [[ ${matched[$selector]:-} = 1 ]] || { echo "Unsupported combination: $selector" >&2; exit 2; }
done
test "$(wc -l < "$log_root/matrix.tsv")" -gt 1
{
    head -1 "$log_root/matrix.tsv"
    for priority in bcm27xx-bcm2709-k6.12 malta-be-k6.18 x86-64-k7.2; do
        awk -F '\t' -v key="$priority" '$1 == key' "$log_root/matrix.tsv"
    done
    awk -F '\t' 'NR > 1 && $1 != "bcm27xx-bcm2709-k6.12" && $1 != "malta-be-k6.18" && $1 != "x86-64-k7.2"' "$log_root/matrix.tsv"
} > "$log_root/matrix.ordered.tsv"
mv "$log_root/matrix.ordered.tsv" "$log_root/matrix.tsv"
else
    test -f "$log_root/matrix.tsv"
    test -d "$run_root/source/.git"
    rm -f "$log_root/CANCELLED"
fi
printf '%s\n' "$run_id" > /data/act/latest-run
printf 'RUNNING\n' > "$log_root/state"
printf 'Batch %s: %s combinations, parallel=%s\n' "$run_id" "$(($(wc -l < "$log_root/matrix.tsv") - 1))" "$parallel"
run_job() (
    set -euo pipefail
    key=$1 target=$2 version=$3 testing=$4 release=$5
    workspace=$run_root/$key
    record=$log_root/$key
    status=FAIL_IMAGE
    cleanup_job() {
        code=$?
        trap - EXIT
        set +e
        if test -f "$log_root/CANCELLED"; then status=CANCELLED; fi
        printf '%s\n' "$status" > "$record/state"
        printf 'JOB_EXIT=%s\n' "$code" > "$record/job-result.txt"
        docker ps -aq --filter "label=agw.act.batch=$run_id" --filter "label=agw.act.job=$key" | xargs -r docker rm -f >/dev/null
        if [[ $status = PASS ]]; then rm -rf -- "$workspace"; fi
        exit "$code"
    }
    trap cleanup_job EXIT
    trap 'exit 143' TERM INT
    if test -d "$workspace"; then
        test -n "$resume_id"
        attempt=$record/attempts/$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID
        mkdir -p "$attempt"
        find "$record" -maxdepth 1 -type f ! -name state -exec cp -p -t "$attempt" {} +
        if test -f "$workspace/openwrt/.config"; then cp -p "$workspace/openwrt/.config" "$attempt/config.interrupted"; fi
        rm -rf -- "$workspace"
    fi
    image=ghcr.io/openwrt/toolchain:${target//\//-}-latest
    timeout 900 docker pull "$image" > "$record/image-pull.log" 2>&1
    status=FAIL_SETUP
    image=$(docker image inspect "$image" --format '{{index .RepoDigests 0}}')
    printf '%s\n' "$image" > "$record/image.digest"
    mkdir -p "$workspace"
    git clone --local --quiet "$run_root/source" "$workspace/openwrt"
    if test -s "$log_root/source.diff"; then git -C "$workspace/openwrt" apply --binary "$log_root/source.diff"; fi
    mkdir -p "$workspace/openwrt/.github/act"
    cp -a "$run_root/source/.github/act/." "$workspace/openwrt/.github/act/"
    sed -i "1s/Local Kernel CI/Local Kernel CI $run_id $key/" "$workspace/openwrt/.github/act/kernel.yml"
    cp -a "$workspace/openwrt/.github/act" "$record/workflow"
    "$act_bin" --version > "$record/act.version"
    set +e
    "$act_bin" -C "$workspace/openwrt" -W "$workspace/openwrt/.github/act/kernel.yml" workflow_dispatch \
        --bind --pull=false --network bridge -P "ubuntu-latest=$image" --container-daemon-socket=- \
        --container-options "--cpus=$jobs --memory=$memory --label=agw.act.batch=$run_id --label=agw.act.job=$key --volume=$record:/results --volume=$root/dl:/cache/dl" \
        --env "ACT_KERNEL_TARGET=${target%/*}" --env "ACT_KERNEL_SUBTARGET=${target#*/}" \
        --env "ACT_KERNEL_VERSION=$version" --env "ACT_KERNEL_RELEASE=$release" \
        --env "ACT_KERNEL_TESTING=$testing" --env "ACT_KERNEL_JOBS=$jobs" \
        2>&1 | tee "$record/act.log"
    code=${PIPESTATUS[0]}
    set -e
    printf 'ACT_EXIT=%s\n' "$code" > "$record/act-result.txt"
    if [[ $code = 0 ]]; then status=PASS; else
        failed_phase=$(sed -n 's/^PHASE=//p' "$record/result.txt" 2>/dev/null || true)
        status=FAIL_${failed_phase:-ACT}
    fi
    exit "$code"
)
declare -A active=()
failures=()
while IFS=$'\t' read -r key target version testing release; do
    [[ $key != key ]] || continue
    if [[ $(cat "$log_root/$key/state" 2>/dev/null || true) = FAIL_* ]] && test -d "$run_root/$key"; then
        failures+=("$key")
    fi
done < "$log_root/matrix.tsv"
while [[ ${#failures[@]} -gt 2 ]]; do
    old=${failures[0]}; failures=("${failures[@]:1}")
    rm -rf -- "$run_root/$old"
    printf 'Archived logs retained; old failure workspace reclaimed.\n' > "$log_root/$old/workspace-reclaimed.txt"
done
result=0
write_summary() {
    status_report "$run_id" > "$log_root/summary.tsv.tmp"
    mv "$log_root/summary.tsv.tmp" "$log_root/summary.tsv"
}
reap_one() {
    local completed= key code=0 pid
    wait -n -p completed "${!active[@]}" || code=$?
    if [[ -z ${completed:-} ]]; then
        for pid in "${!active[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                completed=$pid
                code=0
                wait "$pid" || code=$?
                break
            fi
        done
    fi
    test -n "${completed:-}"
    if [[ $code != 0 ]]; then result=1; fi
    key=${active[$completed]}
    unset 'active[$completed]'
    if [[ $(cat "$log_root/$key/state") != PASS ]]; then
        failures+=("$key")
        if [[ ${#failures[@]} -gt 2 ]]; then
            old=${failures[0]}; failures=("${failures[@]:1}")
            rm -rf -- "$run_root/$old"
            printf 'Archived logs retained; old failure workspace reclaimed.\n' > "$log_root/$old/workspace-reclaimed.txt"
        fi
    fi
    write_summary
}
cancel() {
    trap - INT TERM
    touch "$log_root/CANCELLED"
    docker ps -q --filter "label=agw.act.batch=$run_id" | xargs -r docker stop -t 10 >/dev/null || true
    for pid in "${!active[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    wait || true
    write_summary
    printf 'CANCELLED\n' > "$log_root/state"
    exit 143
}
trap cancel INT TERM
while IFS=$'\t' read -r key target version testing release; do
    [[ $key != key ]] || continue
    previous=$(cat "$log_root/$key/state" 2>/dev/null || echo PENDING)
    case $previous in
        PASS) continue ;;
        FAIL_*) result=1; continue ;;
    esac
    mkdir -p "$log_root/$key"
    printf 'PENDING\n' > "$log_root/$key/state"
    free_kb=$(df -Pk "$work_base" | awk 'NR==2 {print $4}')
    if [[ $free_kb -lt 52428800 ]]; then
        while [[ ${#active[@]} -gt 0 ]]; do reap_one; done
        free_kb=$(df -Pk "$work_base" | awk 'NR==2 {print $4}')
        if [[ $free_kb -lt 52428800 ]]; then printf 'STOPPED_DISK\n' > "$log_root/state"; exit 1; fi
    fi
    printf 'RUNNING\n' > "$log_root/$key/state"
    run_job "$key" "$target" "$version" "$testing" "$release" &
    active[$!]=$key
    write_summary
    while [[ ${#active[@]} -ge $parallel ]]; do reap_one; done
done < "$log_root/matrix.tsv"
while [[ ${#active[@]} -gt 0 ]]; do reap_one; done
sha256sum -c "$log_root/production-config.before.sha256" > "$log_root/config-check.txt" || result=1
if [[ $result = 0 ]]; then printf 'PASS\n' > "$log_root/state"; else printf 'FAIL\n' > "$log_root/state"; fi
printf 'QUEUE_EXIT=%s\n' "$result" > "$log_root/result.txt"
write_summary
echo "Results: $log_root/summary.tsv"
exit "$result"
