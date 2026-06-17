#!/usr/bin/env bash
# Step 3 — install Kueue and enable Topology-Aware Scheduling (TAS).
#
# We install the pinned release via a single manifest, wait for the controller
# to come up, then enable the TopologyAwareScheduling feature gate (it is not
# on by default in this release). Kueue then restarts and is ready.
set -euo pipefail
cd "$(dirname "$0")/.."

# Pinned to the release this lab was tested against. Bump deliberately.
KUEUE_VERSION="v0.18.1"
MANIFEST="https://github.com/kubernetes-sigs/kueue/releases/download/${KUEUE_VERSION}/manifests.yaml"

echo "→ Installing Kueue ${KUEUE_VERSION}…"
kubectl apply --server-side -f "$MANIFEST"

echo
echo "→ Waiting for the kueue-controller-manager deployment to be available…"
kubectl -n kueue-system rollout status deploy/kueue-controller-manager --timeout=180s

# Enable Topology-Aware Scheduling. The feature gate is passed to the manager
# via the controller's container args. We patch it on, then wait for the new
# pod to roll out.
echo
echo "→ Enabling the TopologyAwareScheduling feature gate…"
kubectl -n kueue-system patch deploy/kueue-controller-manager --type=json -p '[
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates=TopologyAwareScheduling=true"}
]'
kubectl -n kueue-system rollout status deploy/kueue-controller-manager --timeout=180s

# The deployment can report "rolled out" a beat before the webhook endpoint is
# actually accepting TLS connections. If we hand off to step 4 too early, the
# first ResourceFlavor create fails with:
#   failed calling webhook "mresourceflavor.kb.io": ... context deadline exceeded
# So wait for the controller Pod to be Ready (its readiness probe gates on the
# webhook serving), then poll the webhook itself with a harmless dry-run create
# until it answers. This hits the exact path the real apply uses.
echo
echo "→ Waiting for the controller Pod to be Ready…"
kubectl -n kueue-system wait --for=condition=Ready pod \
  -l control-plane=controller-manager --timeout=120s

echo "→ Waiting for the Kueue webhooks to start serving…"
# Each object kind has its own webhook, and they come online independently — so
# probe both kinds step 4 creates (ResourceFlavor and ClusterQueue) with a
# server-side dry-run, and only move on once both answer. Probing just one let a
# slower sibling webhook still 500 the first real apply.
for i in $(seq 1 40); do
  if kubectl create -f manifests/03-resourceflavor.yaml --dry-run=server >/dev/null 2>&1 \
     && kubectl create -f manifests/04-clusterqueue.yaml --dry-run=server >/dev/null 2>&1; then
    echo "  ✓ webhooks are answering."
    break
  fi
  [ "$i" = "40" ] && echo "  ! webhooks still not ready after ~120s — step 4 may need a re-run."
  sleep 3
done

echo
echo "✓ Kueue is up. CRDs available:"
kubectl get crd | grep kueue.x-k8s.io | awk '{print "  " $1}'
echo
echo "Next: ./scripts/04-apply-kueue.sh   (topology, flavor, queues)"
