#!/usr/bin/env bash
# Step 1 — create the local multi-node kind cluster.
#
# This is the "datacenter": one control-plane and four worker nodes that will
# stand in for four GPU servers. No GPUs are involved yet — that comes in step 2.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTER=kueue-lab

# --- Preflight: raise inotify limits -----------------------------------------
# A multi-node kind cluster runs every node as a container sharing kernel.
# Each kubelet/cAdvisor opens many inotify instances; the default
# fs.inotify.max_user_instances (often 128 on Docker Desktop / Rancher Desktop /
# Linux) is too low and worker kubelets fail to start with
# "too many open files" / "inotify_init: too many open files" — the nodes then
# never register and you're left with only the control-plane. We raise the
# limit in the Docker VM kernel before creating the cluster.
echo "→ Preflight: raising inotify limits in the Docker VM…"
if docker run --rm --privileged alpine sh -c \
     "sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=1048576" >/dev/null 2>&1; then
  echo "  ✓ inotify limits raised (max_user_instances=8192)."
else
  echo "  ! Could not raise inotify limits automatically."
  echo "    On native Linux run:  sudo sysctl -w fs.inotify.max_user_instances=8192"
  echo "    then re-run this script."
fi

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "✓ kind cluster '$CLUSTER' already exists — skipping create."
else
  echo "→ Creating kind cluster '$CLUSTER' (1 control-plane + 4 workers)…"
  kind create cluster --config manifests/kind-cluster.yaml
fi

echo
echo "→ Waiting for all 5 nodes to register and become Ready (can take ~60s)…"
# Workers join a little after `kind create` returns; give them a moment to
# appear before we wait on readiness.
for _ in $(seq 1 30); do
  [ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')" = "5" ] && break
  sleep 3
done
kubectl wait --for=condition=Ready nodes --all --timeout=180s

echo
echo "→ Nodes:"
kubectl get nodes
echo
echo "Next: ./scripts/02-label-nodes.sh   (apply fake topology + fake GPUs)"
