#!/usr/bin/env bash
# Step 2 — turn plain kind workers into fake GPU servers in a fake datacenter.
#
# Two things happen here:
#
#   (a) Topology labels. We tag each worker with zone / rack / hostname labels.
#       These are ordinary node labels; a real cloud or AI datacenter carries
#       the same kind of thing on its GPU nodes. Kueue's Topology object (step 4)
#       reads them to keep a job's pods close.
#
#   (b) Fake GPUs. A laptop has none, so we advertise them. We patch each
#       worker's status.capacity to claim 8 nvidia.com/gpu. The scheduler treats
#       that as a real, countable resource — a pod asking for nvidia.com/gpu: 1
#       only lands on a node that still has one free.
#
#       Two caveats: capacity patched this way resets if the node restarts, and
#       in production a device plugin advertises GPUs rather than a manual patch.
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Topology label keys. These exact keys are referenced by the Topology object
# in manifests/02-topology.yaml — keep them in sync.
ZONE_LABEL="topology.kubernetes.io/zone"
RACK_LABEL="lab.gpu/rack"
GPU_PER_NODE=8        # a standard HGX H100 node has 8 GPUs

# worker-name : zone : rack : friendly-alias
MAP=(
  "kueue-lab-worker:az1:rack1:gpu-node-1"
  "kueue-lab-worker2:az1:rack1:gpu-node-2"
  "kueue-lab-worker3:az1:rack2:gpu-node-3"
  "kueue-lab-worker4:az1:rack2:gpu-node-4"
)

echo "→ Labeling workers + advertising ${GPU_PER_NODE} fake GPUs each…"
for entry in "${MAP[@]}"; do
  IFS=":" read -r node zone rack alias <<< "$entry"

  # (a) topology labels — overwrite so the script is re-runnable.
  kubectl label node "$node" \
    "${ZONE_LABEL}=${zone}" \
    "${RACK_LABEL}=${rack}" \
    "lab.gpu/alias=${alias}" \
    "lab.gpu/accelerator=fake-h100" \
    --overwrite >/dev/null

  # (b) fake GPU capacity — extended resources live in status.capacity, and the
  # only way to set them is a patch against the status subresource. The '~1' is
  # the JSON-Pointer escape for the '/' in "nvidia.com/gpu".
  kubectl patch node "$node" --subresource=status --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/status/capacity/nvidia.com~1gpu\",\"value\":\"${GPU_PER_NODE}\"}]" \
    >/dev/null

  echo "  ✓ ${node}  →  zone=${zone} rack=${rack} alias=${alias}  +${GPU_PER_NODE} GPU"
done

echo
echo "→ Topology view (zone / rack / fake GPUs):"
kubectl get nodes -L "${ZONE_LABEL}" -L "${RACK_LABEL}" -L lab.gpu/alias \
  -o custom-columns='NODE:.metadata.name,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,RACK:.metadata.labels.lab\.gpu/rack,ALIAS:.metadata.labels.lab\.gpu/alias,GPUS:.status.capacity.nvidia\.com/gpu'

echo
echo "Next: ./scripts/03-install-kueue.sh"
