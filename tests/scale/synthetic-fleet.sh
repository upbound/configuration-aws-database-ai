#!/usr/bin/env bash
# Generate N SQLInstance XRs to drive the WatchOperation path at fleet scale
# without provisioning any RDS.
#
# managementPolicies: [Observe] means the composed RDS Instance is only observed,
# never created, so there is no AWS spend. What this exercises is the expensive
# part of the control plane: WatchOperation -> one Operation per resource ->
# function-openai -> model -> patch. That is where fleet-scale behaviour either
# holds up or falls over (API server churn, Operation GC, GPU saturation).
#
# CAVEAT, and it is a real one: with no real RDS instance there is no CloudWatch
# data, so function-rds-metrics will not populate status.performanceMetrics and
# the model will correctly decide "no metrics, do nothing". That still measures
# throughput and loop stability, but it measures the NO-OP path. To exercise the
# decision path, seed metrics with --seed-metrics, which patches status directly
# after creation. Verify the metrics function does not immediately overwrite it
# in your setup; if it does, use a composition without the fetch-metrics step
# for synthetic load.
#
# Usage:
#   tests/scale/synthetic-fleet.sh 500 [--seed-metrics]
#   tests/scale/synthetic-fleet.sh --delete
set -euo pipefail

NS="${FLEET_NAMESPACE:-database-team}"
PREFIX="${FLEET_PREFIX:-synthetic-scale}"
NETWORK_ID="${FLEET_NETWORK_ID:-rds-metrics-database-ai-scale}"

if [[ "${1:-}" == "--delete" ]]; then
  echo "deleting fleet with prefix $PREFIX in $NS"
  kubectl delete sqlinstance -n "$NS" -l "fleet=$PREFIX" --wait=false
  exit 0
fi

COUNT="${1:?usage: synthetic-fleet.sh N [--seed-metrics] | --delete}"
SEED=false
[[ "${2:-}" == "--seed-metrics" ]] && SEED=true

for i in $(seq 1 "$COUNT"); do
  cat <<YAML
---
apiVersion: aws.platform.upbound.io/v1alpha1
kind: SQLInstance
metadata:
  name: ${PREFIX}-${i}
  namespace: ${NS}
  labels:
    scale: me
    fleet: ${PREFIX}
spec:
  crossplane:
    compositionSelector:
      matchLabels:
        type: rds-metrics
  parameters:
    region: us-west-2
    engine: mariadb
    engineVersion: "10.11"
    storageGB: 5
    instanceClass: db.t3.micro
    autoGeneratePassword: true
    # Observe only: nothing is created in AWS, so this costs nothing.
    managementPolicies:
    - Observe
    passwordSecretRef:
      name: mariadbsecret
      key: password
    networkRef:
      id: ${NETWORK_ID}
YAML
done | kubectl apply -f -

echo "created $COUNT SQLInstances in $NS (label fleet=$PREFIX)"

if [[ "$SEED" == true ]]; then
  echo "seeding status.performanceMetrics and the convergence-gate fields"
  for i in $(seq 1 "$COUNT"); do
    # Vary CPU so some cross the 80% threshold and some do not, giving a
    # realistic mix of scale-up decisions and no-ops.
    cpu=$(( (i * 37) % 100 ))
    kubectl patch sqlinstance "${PREFIX}-${i}" -n "$NS" --subresource=status --type=merge -p "$(cat <<JSON
{"status":{"observedInstanceClass":"db.t3.micro","observedInstanceStatus":"available","performanceMetrics":{"metrics":{"CPUUtilization":{"value":${cpu},"unit":"Percent"},"DatabaseConnections":{"value":10,"unit":"Count"},"FreeableMemory":{"value":800000000,"unit":"Bytes"}}}}}
JSON
)" >/dev/null || echo "  warn: could not patch ${PREFIX}-${i}"
  done
fi

cat <<'NEXT'

Watch what it costs:
  kubectl get operations -l ops.crossplane.io/watchoperation=rds-intelligent-scaling \
    --sort-by=.metadata.creationTimestamp | tail -20
  # Not a churn metric: successfulHistoryLimit GCs Operations, so this pins at
  # its limit. Use it only to confirm GC is keeping up, never as a loop signal.
  kubectl get operations --no-headers | wc -l
  kubectl get sqlinstance -n database-team -o custom-columns=\
NAME:.metadata.name,WANT:.spec.parameters.instanceClass,GOT:.status.observedInstanceClass

Loop-stability check - lastScheduleTime must STOP advancing. Do not count
Operation objects: successfulHistoryLimit GCs them, so the count pins at its
limit whether the loop has settled or is spinning.
  for i in $(seq 1 10); do
    kubectl get watchoperation rds-intelligent-scaling \
      -o jsonpath='{.status.lastScheduleTime}{"\n"}'; sleep 60
  done
NEXT
