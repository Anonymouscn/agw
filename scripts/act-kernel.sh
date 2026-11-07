#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
act_bin=${ACT_BIN:-/data/act/bin/act}
work_base=${ACT_KERNEL_RUN_ROOT:-/data/act/runs}
log_base=${ACT_KERNEL_LOG_ROOT:-/var/log/agw-act}
log_storage=${ACT_KERNEL_LOG_STORAGE:-/data/act/logs}
status_report() {
    local id=${1:-$(cat /data/act/latest-run)} key target version testing release state
    [[ $id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]
    local record=$log_base/$id
    local display_scope=kernel display_feeds=none
    if test -f "$record/scope.env"; then
        display_scope=$(sed -n 's/^SCOPE=//p' "$record/scope.env")
        display_feeds=$(sed -n 's/^FEEDS=//p' "$record/scope.env")
    fi
    printf 'TARGET\tKERNEL\tMODE\tSTATE\tSCOPE\tFEEDS\n'
    while IFS=$'\t' read -r key target version testing release; do
        [[ $key != key ]] || continue
        state=$(cat "$record/$key/state" 2>/dev/null || echo PENDING)
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$target" "$release" "$testing" "$state" "$display_scope" "$display_feeds"
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
scope=${ACT_REGRESSION_SCOPE:-kernel}
feeds_mode=${ACT_REGRESSION_FEEDS:-none}
if [[ -n $resume_id && -f "$log_base/$resume_id/scope.env" ]]; then
    scope=$(sed -n 's/^SCOPE=//p' "$log_base/$resume_id/scope.env")
    feeds_mode=$(sed -n 's/^FEEDS=//p' "$log_base/$resume_id/scope.env")
fi
[[ $scope = kernel || $scope = packages || $scope = firmware ]]
[[ $feeds_mode = none || $feeds_mode = locked ]]
for i in "${!selectors[@]}"; do
    case ${selectors[$i]} in 64|legacy) selectors[$i]=x86/${selectors[$i]} ;; esac
done
jobs=${ACT_KERNEL_JOBS:-11}
if [[ $scope = kernel ]]; then default_tools_jobs=8; else default_tools_jobs=12; fi
tools_jobs=${ACT_KERNEL_TOOLS_JOBS:-$default_tools_jobs}
cpu_mode=${ACT_KERNEL_CPU_MODE:-elastic}
cache_root=${ACT_KERNEL_CACHE_ROOT:-/data/act/cache}
prefetch=${ACT_KERNEL_PREFETCH:-2}
if [[ $scope = kernel ]]; then default_memory=12g; default_parallel=6; else default_memory=12g; default_parallel=6; fi
job_timeout=${ACT_REGRESSION_JOB_TIMEOUT:-24h}
[[ $job_timeout =~ ^[1-9][0-9]*[smhd]$ ]]
memory=${ACT_KERNEL_MEMORY:-$default_memory}
parallel=${ACT_KERNEL_PARALLEL:-$default_parallel}
[[ $jobs =~ ^[1-9][0-9]*$ && $memory =~ ^[1-9][0-9]*[gm]$ ]]
[[ $tools_jobs =~ ^[1-9][0-9]*$ ]]
(( tools_jobs <= $(nproc) ))
[[ $parallel =~ ^[1-9][0-9]*$ ]]
[[ $cpu_mode = elastic || $cpu_mode = quota ]]
[[ $prefetch =~ ^[1-4]$ ]]
if (( jobs > $(nproc) )) || { [[ $cpu_mode = quota ]] && (( jobs * parallel > $(nproc) )); }; then
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
source "$root/.github/act/resource-budget.sh"
command -v "$act_bin" >/dev/null
docker info >/dev/null
mkdir -p "$work_base" "$log_base"
mkdir -p "$cache_root/images" "$cache_root/host-tools" "$cache_root/ccache" "$cache_root/host-cxx" "$cache_root/heavy"
exec 8>/data/act/kernel-queue.lock
flock -n 8 || { echo 'Another kernel regression queue is running' >&2; exit 2; }
run_id=${resume_id:-$(date -u +%Y%m%dT%H%M%SZ)-$$}
[[ $run_id =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]
run_root=$work_base/$run_id
log_root=$log_base/$run_id
mkdir -p "$run_root" "$log_storage"
if [[ ! -e $log_root && ! -L $log_root ]]; then
    mkdir -p "$log_storage/$run_id"
    ln -s "$log_storage/$run_id" "$log_root"
fi
mkdir -p "$log_root"
if [[ -z $resume_id ]]; then
printf 'SCOPE=%s\nFEEDS=%s\n' "$scope" "$feeds_mode" > "$log_root/scope.env"
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
    priorities=(bcm27xx-bcm2709-k6.12 malta-be-k6.18 x86-64-k7.2)
    if [[ $scope != kernel ]]; then priorities=(x86-64-k7.2 malta-be-k6.18 bcm27xx-bcm2709-k6.12); fi
    for priority in "${priorities[@]}"; do
        awk -F '\t' -v key="$priority" '$1 == key' "$log_root/matrix.tsv"
    done
    awk -F '\t' 'NR > 1 && $1 != "bcm27xx-bcm2709-k6.12" && $1 != "malta-be-k6.18" && $1 != "x86-64-k7.2"' "$log_root/matrix.tsv"
} > "$log_root/matrix.ordered.tsv"
mv "$log_root/matrix.ordered.tsv" "$log_root/matrix.tsv"
if [[ $scope != kernel ]]; then
    python3 "$run_root/source/.github/act/regression-plan.py" "$log_root/matrix.tsv" \
        --parallel "$parallel" --scope "$scope" --feeds "$feeds_mode" \
        --feed-lock "$run_root/source/.github/regression/feeds.lock.json" --output "$log_root/plan.json"
fi
else
    test -f "$log_root/matrix.tsv"
    test -d "$run_root/source/.git"
    rm -f "$log_root/CANCELLED"
fi
printf '%s\n' "$run_id" > /data/act/latest-run
printf 'RUNNING\n' > "$log_root/state"
printf 'Batch %s: %s combinations, parallel=%s\n' "$run_id" "$(($(wc -l < "$log_root/matrix.tsv") - 1))" "$parallel"
pull_image() (
    target=$1
    image=ghcr.io/openwrt/toolchain:${target//\//-}-latest
    image_key=${target//\//-}
    exec 9>"$cache_root/images/$image_key.lock"
    flock 9
    if ! test -s "$log_root/images/$image_key.digest"; then
        # Bound foreground and speculative pulls together, not just prefetch.
        acquired=0
        while (( acquired == 0 )); do
            for ((slot=0; slot<prefetch; slot++)); do
                exec {pull_slot}>"$cache_root/images/pull-$slot.lock"
                if flock -n "$pull_slot"; then acquired=1; break; fi
                exec {pull_slot}>&-
            done
            if (( acquired == 0 )); then sleep 1; fi
        done
        timeout 900 docker pull "$image" > "$log_root/images/$image_key.log" 2>&1
        docker image inspect "$image" --format '{{index .RepoDigests 0}}' > "$log_root/images/$image_key.digest.tmp"
        mv "$log_root/images/$image_key.digest.tmp" "$log_root/images/$image_key.digest"
    fi
)
mkdir -p "$log_root/images"
# Preserve already recorded toolchains when resuming a frozen batch.
while IFS=$'\t' read -r key target version testing release; do
    [[ $key != key ]] || continue
    image_key=${target//\//-}
    if ! test -s "$log_root/images/$image_key.digest" && test -s "$log_root/$key/image.digest"; then
        digest=$(cat "$log_root/$key/image.digest")
        if docker image inspect "$digest" >/dev/null 2>&1; then
            cp "$log_root/$key/image.digest" "$log_root/images/$image_key.digest"
            if test -f "$log_root/$key/image-pull.log"; then
                cp "$log_root/$key/image-pull.log" "$log_root/images/$image_key.log"
            else
                printf 'Reusing recorded image %s\n' "$digest" > "$log_root/images/$image_key.log"
            fi
        fi
    fi
done < "$log_root/matrix.tsv"
prefetch_images() (
    exec 8>&-
    trap 'jobs -pr | xargs -r kill -TERM; exit 0' TERM INT
    while true; do
        declare -A seen=()
        count=0; window=0
        while IFS=$'\t' read -r key target version testing release; do
            [[ $key != key ]] || continue
            case $(cat "$log_root/$key/state" 2>/dev/null || true) in PASS|FAIL_*) continue ;; esac
            window=$((window + 1))
            if (( window > parallel + prefetch )); then break; fi
            [[ ${seen[$target]:-} != 1 ]] || continue
            seen[$target]=1
            test ! -s "$log_root/images/${target//\//-}.digest" || continue
            pull_image "$target" &
            count=$((count + 1))
            if (( count >= prefetch )); then wait || true; count=0; fi
        done < "$log_root/matrix.tsv"
        wait || true
        sleep 10 & wait $! || true
    done
)
prefetch_images > "$log_root/prefetch.log" 2>&1 &
prefetch_pid=$!
trap 'kill -TERM "$prefetch_pid" 2>/dev/null || true; wait "$prefetch_pid" 2>/dev/null || true' EXIT
run_job() (
    set -euo pipefail
    key=$1 target=$2 version=$3 testing=$4 release=$5
    workspace=$run_root/$key
    record=$log_root/$key
    reused=0
    tools_volume=agw-tools-$run_id-$key
    status=FAIL_SETUP
    cleanup_job() {
        code=$?
        trap - EXIT
        set +e
        if test -f "$log_root/CANCELLED"; then status=CANCELLED; fi
        printf '%s\n' "$status" > "$record/state"
        printf 'JOB_EXIT=%s\n' "$code" > "$record/job-result.txt"
        docker ps -aq --filter "label=agw.act.batch=$run_id" --filter "label=agw.act.job=$key" | xargs -r docker rm -f >/dev/null
        if [[ $status = PASS ]]; then rm -rf -- "$workspace"; docker volume rm "$tools_volume" >/dev/null 2>&1 || true; fi
        exit "$code"
    }
    trap cleanup_job EXIT
    trap 'exit 143' TERM INT
    if test -d "$workspace" || test -d "$record/workflow"; then
        test -n "$resume_id"
        attempt=$record/attempts/$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID
        mkdir -p "$attempt"
        find "$record" -maxdepth 1 -type f ! -name state -exec cp -p -t "$attempt" {} +
        if test -d "$record/workflow"; then cp -a "$record/workflow" "$attempt/workflow"; fi
        if test -f "$workspace/openwrt/.config"; then cp -p "$workspace/openwrt/.config" "$attempt/config.interrupted"; fi
        rm -rf -- "$workspace"
    fi
    status=FAIL_IMAGE
    pull_image "$target"
    cp "$log_root/images/${target//\//-}.log" "$record/image-pull.log"
    status=FAIL_SETUP
    image=$(cat "$log_root/images/${target//\//-}.digest")
    if [[ -n ${ACT_KERNEL_SEED_RUN:-} ]]; then
        seed=$ACT_KERNEL_SEED_RUN
        [[ $seed =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]
        product_fingerprint() {
            python3 "$root/.github/act/product-fingerprint.py" "$1"
        }
        if test -d "$work_base/$seed/$key/openwrt/.git" &&
           test "$(cat "$log_base/$seed/state")" = CANCELLED &&
           test "$(cat "$log_base/$seed/$key/image.digest")" = "$image" &&
           cmp -s "$log_base/$seed/scope.env" "$log_root/scope.env" &&
           test "$(product_fingerprint "$work_base/$seed/source")" = "$(product_fingerprint "$run_root/source")"; then
            docker volume inspect "agw-tools-$seed-$key" >/dev/null
            mv "$work_base/$seed/$key" "$workspace"
            reused=1
            tools_volume=agw-tools-$seed-$key
            printf 'SEED=%s\nPRODUCT_SOURCE_VERIFIED=1\n' "$seed" > "$record/reused-workspace.env"
        fi
    fi
    if [[ $scope != kernel && $feeds_mode = locked ]]; then
        mkdir -p "$cache_root/host-cxx"
        exec 6>"$cache_root/host-cxx.lock"
        flock 6
        if ! test -f "$cache_root/host-cxx/complete"; then
            docker run --rm --entrypoint=/bin/bash --user=0 \
                --volume="$cache_root/host-cxx:/export" \
                --volume="$run_root/source/.github/workflows/scripts/setup_host_cxx.sh:/setup-host-cxx.sh:ro" \
                "$image" /setup-host-cxx.sh /export > "$log_root/host-cxx-setup.log" 2>&1
        fi
        if ! test -f "$log_root/host-cxx-verified"; then
            (cd "$cache_root/host-cxx"; sha256sum -c SHA256SUMS) > "$log_root/host-cxx-check.log"
            cp "$cache_root/host-cxx/packages.tsv" "$log_root/host-cxx-packages.tsv"
            touch "$log_root/host-cxx-verified"
        fi
        flock -u 6
    fi
    printf '%s\n' "$image" > "$record/image.digest"
    mkdir -p "$workspace"
    if (( reused == 0 )); then
        git clone --local --quiet "$run_root/source" "$workspace/openwrt"
        if test -s "$log_root/source.diff"; then git -C "$workspace/openwrt" apply --binary "$log_root/source.diff"; fi
    fi
    mkdir -p "$workspace/openwrt/.github/act"
    cp -a "$run_root/source/.github/act/." "$workspace/openwrt/.github/act/"
    sed -i "1s/Local Kernel CI/Local Kernel CI $run_id $key/" "$workspace/openwrt/.github/act/kernel.yml"
    rm -rf -- "$record/workflow"
    mkdir -p "$record/workflow"
    cp -a "$workspace/openwrt/.github/act/." "$record/workflow/"
    "$act_bin" --version > "$record/act.version"
    cache_key=$( { printf '%s\n' "$image" "$target" "$version" "$testing" "$scope" "$feeds_mode"; git -C "$run_root/source" rev-parse HEAD; cat "$log_root/source.diff"; sha256sum < "$workspace/openwrt/.github/act/kernel-build.sh"; } | sha256sum | cut -d' ' -f1)
    printf '%s\n' "$cache_key" > "$record/host-tools-cache.key"
    printf 'CPU_MODE=%s\nMAKE_JOBS=%s\nTOOLS_JOBS=%s\nMEMORY=%s\nPARALLEL=%s\nPULL_LIMIT=%s\n' "$cpu_mode" "$jobs" "$tools_jobs" "$memory" "$parallel" "$prefetch" > "$record/resources.env"
    printf 'SCOPE=%s\nFEEDS=%s\nJOB_TIMEOUT=%s\n' "$scope" "$feeds_mode" "$job_timeout" >> "$record/resources.env"
    cpu_options=--cpu-shares=1024
    if [[ $cpu_mode = quota ]]; then cpu_options="--cpus=$jobs"; fi
    set +e
    timeout --signal=TERM --kill-after=120s "$job_timeout" "$act_bin" -C "$workspace/openwrt" -W "$workspace/openwrt/.github/act/kernel.yml" workflow_dispatch \
        --bind --pull=false --network bridge -P "ubuntu-latest=$image" --container-daemon-socket=- \
        --container-options "$cpu_options --memory=$memory --memory-swap=$memory --label=agw.act.batch=$run_id --label=agw.act.job=$key --volume=$workspace/openwrt:/workspace/openwrt --volume=$record:/results --volume=$root/dl:/cache/dl --volume=$cache_root/host-tools:/cache/host-tools --volume=$cache_root/ccache:/cache/ccache --volume=$cache_root/host-cxx:/opt/agw-host-compiler:ro --volume=$cache_root/heavy:/cache/heavy --volume=$tools_volume:/prebuilt_tools" \
        --env "ACT_WORKSPACE_REUSED=$reused" \
        --env "ACT_KERNEL_TOOLS_KEY=$cache_key" \
        --env "ACT_KERNEL_TARGET=${target%/*}" --env "ACT_KERNEL_SUBTARGET=${target#*/}" \
        --env "ACT_KERNEL_VERSION=$version" --env "ACT_KERNEL_RELEASE=$release" \
        --env "ACT_KERNEL_TESTING=$testing" --env "ACT_KERNEL_JOBS=$jobs" \
        --env "ACT_KERNEL_TOOLS_JOBS=$tools_jobs" \
        --env "ACT_REGRESSION_SCOPE=$scope" --env "ACT_REGRESSION_FEEDS=$feeds_mode" \
        2>&1 | tee "$record/act.log"
    code=${PIPESTATUS[0]}
    set -e
    printf 'ACT_EXIT=%s\n' "$code" > "$record/act-result.txt"
    if [[ $code = 0 ]]; then status=PASS; elif [[ $code = 124 ]]; then status=FAIL_TIMEOUT; else
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
    docker volume rm "agw-tools-$run_id-$old" >/dev/null 2>&1 || true
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
            if test -f "$log_root/$old/KEEP_WORKSPACE"; then
                write_summary
                return
            fi
            rm -rf -- "$run_root/$old"
    docker volume rm "agw-tools-$run_id-$old" >/dev/null 2>&1 || true
            printf 'Archived logs retained; old failure workspace reclaimed.\n' > "$log_root/$old/workspace-reclaimed.txt"
        fi
    fi
    write_summary
}
cancel() {
    trap - INT TERM
    touch "$log_root/CANCELLED"
    kill -TERM "$prefetch_pid" 2>/dev/null || true
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
    if test -f "$log_root/DRAIN"; then break; fi
    previous=$(cat "$log_root/$key/state" 2>/dev/null || echo PENDING)
    case $previous in
        PASS) continue ;;
        FAIL_*) result=1; continue ;;
    esac
    mkdir -p "$log_root/$key"
    printf 'PENDING\n' > "$log_root/$key/state"
    if [[ $scope != kernel ]]; then
        while ! regression_resources_fit "$((${#active[@]} + 1))"; do
            printf '%s waiting: active=%s, requested jobs=%s memory=%s\n' "$(date -u +%FT%TZ)" "${#active[@]}" "$jobs" "$memory" >> "$log_root/resource-waits.log"
            if (( ${#active[@]} > 0 )); then reap_one; else sleep 5; fi
        done
    fi
    free_kb=$(df -Pk "$work_base" | awk 'NR==2 {print $4}')
    reserve_kb=52428800
    if [[ $scope != kernel ]]; then reserve_kb=$((104857600 + ${#active[@]} * 67108864)); fi
    if (( free_kb < reserve_kb )); then
        while [[ ${#active[@]} -gt 0 ]]; do reap_one; done
        if [[ $scope != kernel ]]; then reserve_kb=104857600; fi
        free_kb=$(df -Pk "$work_base" | awk 'NR==2 {print $4}')
        # Keep diagnostics; reclaim failed generated trees before blocking the matrix.
        for old in "${failures[@]}"; do
            (( free_kb < reserve_kb )) || break
            test ! -f "$log_root/$old/KEEP_WORKSPACE" || continue
            rm -rf -- "$run_root/$old"
            docker volume rm "agw-tools-$run_id-$old" >/dev/null 2>&1 || true
            printf 'Archived diagnostics retained; workspace reclaimed for disk reserve.\n' > "$log_root/$old/workspace-reclaimed.txt"
            free_kb=$(df -Pk "$work_base" | awk 'NR==2 {print $4}')
        done
        if (( free_kb < reserve_kb )); then printf 'STOPPED_DISK\n' > "$log_root/state"; exit 1; fi
    fi
    printf 'RUNNING\n' > "$log_root/$key/state"
    run_job "$key" "$target" "$version" "$testing" "$release" &
    active[$!]=$key
    write_summary
    while [[ ${#active[@]} -ge $parallel ]]; do reap_one; done
done < "$log_root/matrix.tsv"
while [[ ${#active[@]} -gt 0 ]]; do reap_one; done
kill -TERM "$prefetch_pid" 2>/dev/null || true
wait "$prefetch_pid" 2>/dev/null || true
if test -f "$log_root/DRAIN"; then
    printf 'DRAINED\n' > "$log_root/state"
    write_summary
    exit 0
fi
sha256sum -c "$log_root/production-config.before.sha256" > "$log_root/config-check.txt" || result=1
if [[ $scope != kernel ]]; then
    python3 "$run_root/source/.github/act/regression-summary.py" --plan "$log_root/plan.json" \
        --reports "$log_root" --output "$log_root/coverage-summary.json" --require-complete || result=1
fi
if [[ $result = 0 ]]; then printf 'PASS\n' > "$log_root/state"; else printf 'FAIL\n' > "$log_root/state"; fi
printf 'QUEUE_EXIT=%s\n' "$result" > "$log_root/result.txt"
write_summary
echo "Results: $log_root/summary.tsv"
exit "$result"
