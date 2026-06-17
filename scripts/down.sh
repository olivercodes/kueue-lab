#!/usr/bin/env bash
# Teardown — delete the whole kind cluster. Nothing persists on your laptop
# afterward (kind runs entirely in Docker).
set -euo pipefail
CLUSTER=kueue-lab
echo "→ Deleting kind cluster '$CLUSTER'…"
kind delete cluster --name "$CLUSTER"
echo "✓ Gone. Your laptop is back to normal."
