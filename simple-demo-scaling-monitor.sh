#!/bin/bash
# simple-demo-scaling-monitor.sh

XR_NAME="rds-metrics-database-ai-scale"
CONTEXT="kind-up-configuration-aws-database-ai"

while true; do
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo "$ kubectl get xsqlinstance $XR_NAME -o yaml | yq '.metadata.annotations |
del(.[\"kubectl.kubernetes.io/last-applied-configuration\"])'"

    kubectl --context $CONTEXT get xsqlinstance $XR_NAME -o yaml | yq '.metadata.annotations |
del(.["kubectl.kubernetes.io/last-applied-configuration"])'

    echo ""
    sleep 45
done
