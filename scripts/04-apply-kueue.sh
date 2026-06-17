#!/usr/bin/env bash
# Step 4 — model the datacenter in Kueue.
#
# Apply, in order: the Topology, the ResourceFlavor that points at it, the two
# ClusterQueues (one quota pool per team), and the two LocalQueues (each team's
# entry point).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ Applying Kueue objects (topology → flavor → cluster queues → local queues)…"
kubectl apply -f manifests/02-topology.yaml
kubectl apply -f manifests/03-resourceflavor.yaml
kubectl apply -f manifests/04-clusterqueue.yaml
kubectl apply -f manifests/05-localqueue.yaml
kubectl apply -f manifests/06-priority-classes.yaml

echo
echo "→ Waiting for both ClusterQueues to become Active…"
kubectl wait --for=condition=Active clusterqueue/gpu-team-a clusterqueue/gpu-team-b --timeout=60s

echo
echo "→ Queue state (two tenants, 16 GPU each):"
kubectl get clusterqueue
kubectl get localqueue -n default
echo
echo "Next: in a 2nd terminal →  ./scripts/watch-viz.sh   (live datacenter view)"
echo "      then submit a job →  kubectl apply -f jobs/01-single-gpu.yaml"
