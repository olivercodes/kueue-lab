#!/usr/bin/env bash
# Live datacenter view — the visual way to watch Kueue work.
#
# Run this in a second terminal, then submit jobs in your first terminal and
# watch the GPU slots fill, the quota bar grow, and waiting jobs sit in the
# queue until room frees up. Ctrl-C to stop.
#
# It just redraws scripts/viz.py every 2s. (watch.sh is the raw-kubectl-tables
# version if you'd rather see the underlying objects.)
set -euo pipefail
cd "$(dirname "$0")/.."

PY=$(command -v python3 || command -v python || true)
if [ -z "$PY" ]; then
  echo "python3 not found — falling back to ./scripts/watch.sh"
  exec ./scripts/watch.sh
fi

trap 'tput cnorm 2>/dev/null || true; exit 0' INT TERM
tput civis 2>/dev/null || true   # hide cursor while looping

while true; do
  frame=$("$PY" scripts/viz.py 2>&1)
  clear
  printf '%s\n' "$frame"
  printf '\n  %s\n' "$(date '+%H:%M:%S')  ·  refreshing every 2s  ·  Ctrl-C to stop"
  sleep 2
done
