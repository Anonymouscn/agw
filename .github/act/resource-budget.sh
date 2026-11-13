#!/usr/bin/env bash
# Reservation format: systemd-unit:memory-GiB:CPU-slots, separated by spaces.
regression_reap_ready() {
    local pid
    for pid in "${!active[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            reap_one "$pid"
            return 0
        fi
    done
    return 1
}

regression_resources_fit() {
    local wanted=$1 reserved_memory=0 reserved_cpu=0 entry unit gib slots
    for entry in ${ACT_KERNEL_RESERVATIONS:-}; do
        IFS=: read -r unit gib slots <<< "$entry"
        [[ $gib =~ ^[1-9][0-9]*$ && $slots =~ ^[1-9][0-9]*$ ]] || return 2
        if systemctl is-active --quiet "$unit"; then
            reserved_memory=$((reserved_memory + gib * 1073741824))
            reserved_cpu=$((reserved_cpu + slots))
        fi
    done
    (( wanted * memory_bytes + reserved_memory <= total_memory * 1024 &&
       wanted * jobs + reserved_cpu <= $(nproc) * ${cpu_overcommit:-1} ))
}
