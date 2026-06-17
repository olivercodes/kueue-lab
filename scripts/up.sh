#!/usr/bin/env bash
# One-shot setup: runs steps 1-4 in order. Use this if you just want a working
# cluster fast; run the numbered scripts individually to learn each step.
set -euo pipefail
cd "$(dirname "$0")"
./01-create-cluster.sh
./02-label-nodes.sh
./03-install-kueue.sh
./04-apply-kueue.sh
echo
echo "✓ Lab is ready."
echo "    1) In a second terminal, start the live datacenter view:"
echo "         ./scripts/watch-viz.sh"
echo "    2) Back here, submit jobs and watch the slots fill:"
echo "         kubectl apply -f jobs/01-single-gpu.yaml"
echo "         kubectl apply -f jobs/02-topology-gang.yaml"
echo "         kubectl apply -f jobs/03-over-quota.yaml"
