#!/usr/bin/env bash
# Observe what Kueue is doing. Run this in a second terminal after submitting a
# job. Ctrl-C to stop.
#
# The three things to watch:
#   WORKLOADS  — Kueue's record of each Job. ADMITTED=True means it cleared
#                quota and topology and was handed to Kubernetes to run.
#   QUEUE      — how much of the 8-GPU pool is reserved right now.
#   PODS       — where pods actually landed (NODE column = which fake GPU node).
set -euo pipefail
NS=default

watch -n 2 "
echo '===== WORKLOADS (Kueue admission) =====';
kubectl get workloads -n $NS -o custom-columns='NAME:.metadata.name,QUEUE:.spec.queueName,ADMITTED:.status.conditions[?(@.type==\"Admitted\")].status,RESERVED-GPU:.status.admission.podSetAssignments[0].resourceUsage.nvidia\.com/gpu' 2>/dev/null;
echo;
echo '===== CLUSTERQUEUE (quota use) =====';
kubectl get clusterqueue gpu-cluster-queue -o wide 2>/dev/null;
echo;
echo '===== PODS (placement: see NODE column) =====';
kubectl get pods -n $NS -o wide 2>/dev/null
"
