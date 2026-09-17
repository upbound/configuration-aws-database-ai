#!/usr/bin/env bash
# Prepare a CPU workload cluster for Modelplane to deploy models onto, and
# register it with the control plane.
#
# TWO clusters are required. Pointing an InferenceCluster at the control plane
# itself fails permanently: the control-plane InferenceGateway (Traefik)
# composes the Gateway API CRDs, the ServingStack installs them again via Envoy
# Gateway's chart, and the second install loses a server-side-apply conflict on
# .metadata.annotations.gateway.networking.k8s.io/channel. See the README.
#
# This script touches both clusters and uses explicit --context for every call,
# because the failure mode of getting it wrong is silent:
#
#   WORKLOAD cluster  - DRA driver (so a claimable device exists) and the
#                       modelplane.ai/pool node label (or worker pods stay
#                       Pending with no explanation)
#   CONTROL cluster   - the kubeconfig Secret in modelplane-system, holding the
#                       workload cluster's --internal address (a plain
#                       kubeconfig points at 127.0.0.1, which means nothing to
#                       a provider pod in another cluster)
#
# Usage:
#   platform/cpu-fleet/setup.sh WORKLOAD_CLUSTER CONTROL_CLUSTER [POOL_NAME]
#   platform/cpu-fleet/setup.sh rds-ai-workload rds-ai-e2e cpu-synthetic
set -euo pipefail

WL="${1:?usage: setup.sh WORKLOAD_CLUSTER CONTROL_CLUSTER [POOL_NAME]}"
CP="${2:?usage: setup.sh WORKLOAD_CLUSTER CONTROL_CLUSTER [POOL_NAME]}"
POOL="${3:-cpu-synthetic}"
SECRET="${SECRET_NAME:-cpu-local-kubeconfig}"

[[ "$WL" == "$CP" ]] && {
  echo "workload and control plane must be DIFFERENT clusters - see the README" >&2
  exit 1; }

command -v kind >/dev/null || { echo "kind not found" >&2; exit 1; }
for c in "$WL" "$CP"; do
  kind get clusters 2>/dev/null | grep -qx "$c" || {
    echo "no kind cluster named '$c'" >&2; exit 1; }
done

WLCTX="kind-$WL"
CPCTX="kind-$CP"

# DRA needs the GA resource.k8s.io APIs. Fail early and clearly rather than
# halfway through a serving-stack install.
ver="$(kubectl --context "$WLCTX" get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
case "$ver" in
v1.3[4-9].*|v1.[4-9][0-9].*) echo "workload cluster on $ver - DRA APIs available" ;;
*) echo "workload cluster is $ver; 1.34+ required for the GA DRA APIs." >&2
   echo "Recreate it with: kind create cluster --name $WL --image kindest/node:v1.34.0" >&2
   exit 1 ;;
esac

echo "1/5 [workload] installing the DRA example driver"
kubectl --context "$WLCTX" apply -f "$(dirname "$0")/00-dra-example-driver.yaml" >/dev/null
kubectl --context "$WLCTX" -n dra-example-driver \
  rollout status ds/dra-example-driver-kubeletplugin --timeout=180s

# kind provides no LoadBalancer, and the ServingStack's Envoy Gateway needs one:
# without it the Gateway never reports Programmed, its Service sits at
# <pending>, and the InferenceCluster stalls at
# "Ready=False  Unready resources: gateway" with nothing else looking wrong.
#
# The pool must be inside the kind subnet and must NOT overlap the control
# plane gateway's pool (.255.200-.250, set by apply-inference-gateway.sh), so
# this takes .255.100-.149 - the same split Modelplane's own e2e uses.
echo "2/5 [workload] installing MetalLB (Envoy Gateway needs a LoadBalancer)"
subnet="$(docker network inspect kind \
  -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' | grep -v ':' | head -1)"
prefix="${subnet%.*.*/*}"
kubectl --context "$WLCTX" apply -f \
  "https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml" >/dev/null
kubectl --context "$WLCTX" -n metallb-system rollout status deploy/controller --timeout=240s
kubectl --context "$WLCTX" apply -f - >/dev/null <<POOL
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses: ["${prefix}.255.100-${prefix}.255.149"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools: [kind-pool]
POOL
echo "     pool ${prefix}.255.100-${prefix}.255.149 (control plane uses .200-.250)"

echo "3/5 [workload] labelling nodes modelplane.ai/pool=$POOL"
kubectl --context "$WLCTX" label nodes --all "modelplane.ai/pool=$POOL" --overwrite >/dev/null
kubectl --context "$WLCTX" get nodes -L modelplane.ai/pool --no-headers \
  | awk '{print "     " $1 " -> " $NF}'

echo "4/5 [control] writing the workload kubeconfig Secret to modelplane-system"
kubectl --context "$CPCTX" create namespace modelplane-system \
  --dry-run=client -o yaml | kubectl --context "$CPCTX" apply -f - >/dev/null
kc="$(mktemp)"; trap 'rm -f "$kc"' EXIT
# --internal: the address must be reachable from the control plane's provider
# pods across the shared kind Docker network, not from the host.
kind get kubeconfig --internal --name "$WL" > "$kc"
kubectl --context "$CPCTX" -n modelplane-system create secret generic "$SECRET" \
  --from-file=kubeconfig="$kc" --dry-run=client -o yaml \
  | kubectl --context "$CPCTX" apply -f - >/dev/null
echo "     secret modelplane-system/$SECRET on $CP -> $WL (--internal address)"

echo "5/5 [workload] confirming a claimable device is published"
if kubectl --context "$WLCTX" get resourceslices \
     -o jsonpath='{range .items[*]}{.spec.driver}{"\n"}{end}' 2>/dev/null \
     | grep -qx "gpu.example.com"; then
  kubectl --context "$WLCTX" get resourceslices --no-headers 2>/dev/null \
    | awk '{print "     slice: " $1}'
else
  echo "     WARNING: no gpu.example.com ResourceSlice yet." >&2
  echo "     Without one, ModelDeployments report InsufficientCapacity. Check:" >&2
  echo "       kubectl --context $WLCTX -n dra-example-driver logs ds/dra-example-driver-kubeletplugin" >&2
fi

cat <<NEXT

Ready. Everything below runs against the CONTROL plane ($CP):

  kubectl --context $CPCTX apply -f platform/cpu-fleet/10-inference-class.yaml
  kubectl --context $CPCTX apply -f platform/cpu-fleet/20-inference-cluster.yaml
  kubectl --context $CPCTX get inferencecluster cpu-local -w   # serving stack, several minutes

  kubectl --context $CPCTX apply -f platform/cpu-fleet/30-model-incumbent.yaml
  kubectl --context $CPCTX apply -f platform/cpu-fleet/40-model-challenger.yaml
  kubectl --context $CPCTX get modeldeployment,modelreplica -n ml-team -w

  kubectl --context $CPCTX apply -f platform/cpu-fleet/50-model-service-canary.yaml
  kubectl --context $CPCTX get ms rds-scaler -n ml-team -o jsonpath='{.status.address}'

Then point the scaling operation at it:
  tests/e2e-local/set-model-endpoint.sh modelservice ml-team rds-scaler
NEXT
