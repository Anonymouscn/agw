#!/usr/bin/env bash
set -euo pipefail
cd "${1:?source root required}"
metadata=$(mktemp)
trap 'rm -f "$metadata"' EXIT
if [[ -n ${2:-} ]]; then cp "$2" "$metadata"; else perl scripts/dump-target-info.pl kernels > "$metadata"; fi
test -s "$metadata"
printf 'key\ttarget\tkernel\ttesting\trelease\n'
emit() {
    local target=$1 kernel=$2 testing=$3 suffix
    [[ $target =~ ^[a-zA-Z0-9_]+/[a-zA-Z0-9_]+$ ]]
    [[ $kernel =~ ^[0-9]+\.[0-9]+$ ]]
    suffix=$(awk -v key="LINUX_VERSION-$kernel" '$1 == key {print $NF; exit}' "target/linux/generic/kernel-$kernel")
    [[ $suffix =~ ^\.[0-9]+$ ]]
    printf '%s-k%s\t%s\t%s\t%s\t%s%s\n' "${target//\//-}" "$kernel" "$target" "$kernel" "$testing" "$kernel" "$suffix"
}
while read -r target stable testing rest; do
    test -n "$target" || continue
    emit "$target" "$stable" 0
    if [[ -n $testing && $testing != "$stable" ]]; then emit "$target" "$testing" 1; fi
done < "$metadata"
