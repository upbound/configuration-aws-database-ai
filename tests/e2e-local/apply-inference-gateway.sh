#!/usr/bin/env bash
# Apply an InferenceGateway sized for the local kind network.
#
# platform/20-inference-gateway.yaml is the cloud variant: EKS supports
# LoadBalancer Services natively, so it carries no loadBalancer block. kind does
# not, so the gateway needs MetalLB and an address pool.
#
# The pool MUST sit inside the kind Docker network's real IPv4 subnet. That is
# usually 172.18.0.0/16, but Docker bumps it to .19/.20/... when earlier
# networks already hold 172.18 - on this machine it may well not be .18. A
# hardcoded pool leaves the LoadBalancer IP off-subnet and every request to the
# gateway silently times out, which is a genuinely horrible thing to debug.
#
# Note the kind network usually lists an IPv6 subnet FIRST, so indexing
# .IPAM.Config 0 returns the wrong address family. Filter for the IPv4 one.
set -euo pipefail

NETWORK="${KIND_NETWORK:-kind}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-40.2.0}"

subnet="$(docker network inspect "$NETWORK" \
  -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' | grep -v ':' | head -1)"
if [[ -z "$subnet" ]]; then
  echo "could not find an IPv4 subnet on Docker network '$NETWORK'" >&2
  exit 1
fi

prefix="${subnet%.*.*/*}"          # 172.19.0.0/16 -> 172.19
pool="${prefix}.255.200-${prefix}.255.250"
echo "kind network $NETWORK subnet=$subnet -> MetalLB pool $pool"

kubectl apply -f - <<YAML
apiVersion: modelplane.ai/v1alpha1
kind: InferenceGateway
metadata:
  name: default
spec:
  backend: Traefik
  traefik:
    version: "${TRAEFIK_VERSION}"
    loadBalancer: MetalLB
    metallb:
      addressPool: "${pool}"
YAML

cat <<'NEXT'

The gateway installs Traefik and MetalLB, which takes a few minutes:
  kubectl get inferencegateway default -w
  kubectl get pods -A | grep -Ei 'traefik|metallb'

Once ready it publishes an address on the pool above:
  kubectl get inferencegateway default -o jsonpath='{.status.address}'
NEXT
