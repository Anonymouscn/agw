#!/usr/bin/env bash
set -euo pipefail
budget=${ACT_CPU_BUDGET:-70}
[[ $budget =~ ^[1-9][0-9]*$ ]] && (( budget <= $(nproc) ))
plan() {
    local count=$1 i
    for ((i=0; i<count; i++)); do
        printf '%s\n' "$((budget / count + (i < budget % count)))"
    done
}
if [[ ${1:-} = --plan ]]; then plan "${2:?worker count}"; exit; fi
batch=${1:?batch id}
record=${ACT_CPU_RECORD:?}
mkdir -p "$record"
declare -A applied=()
while systemctl is-active --quiet agw-six-regression; do
    mapfile -t containers < <(docker ps -q --filter "label=agw.act.batch=$batch" | sort)
    if systemctl is-active --quiet agw-repair-x86-round1; then
        containers+=(agw-repair-x86-64-k7.2)
    fi
    if systemctl is-active --quiet agw-repair-mips-parallel; then
        containers+=(agw-repair-malta-be-k6.18)
    fi
    count=${#containers[@]}
    if (( count > 0 )); then
        mapfile -t quotas < <(plan "$count")
        for ((i=0; i<count; i++)); do
            name=${containers[$i]} quota=${quotas[$i]}
            # Existing Make graphs keep their jobserver sizes; do not restart them.
            if [[ ${applied[$name]:-0} != "$quota" ]]; then
                if docker update --cpus="$quota" "$name" >> "$record/docker-update.log" 2>&1; then
                    applied[$name]=$quota
                    printf '%s %s CPUs=%s\n' "$(date -u +%FT%TZ)" "$name" "$quota" >> "$record/allocations.log"
                fi
            fi
        done
    fi
    sleep 15
done
