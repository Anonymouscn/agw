#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ACT_REGRESSION_SCOPE=${ACT_REGRESSION_SCOPE:-packages}
export ACT_REGRESSION_FEEDS=${ACT_REGRESSION_FEEDS:-locked}
exec bash "$root/scripts/act-kernel.sh" "$@"
