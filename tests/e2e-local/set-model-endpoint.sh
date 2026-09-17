#!/usr/bin/env bash
# Point the scaling WatchOperation at a model endpoint by (re)creating the `gpt`
# Secret that function-openai reads.
#
# Everything about which model serves these decisions lives in this Secret, so
# switching between the mock engine, a CPU model, a Modelplane ModelService or a
# hosted provider is one command and no manifest change.
#
# Why this is a script rather than a documented kubectl line: OPENAI_BASE_URL
# defaults to api.openai.com and OPENAI_MODEL to gpt-4 when absent. A typo in a
# key name therefore does not fail - it quietly sends your scaling decisions to
# OpenAI. This verifies the endpoint answers before writing the Secret.
#
# Usage:
#   tests/e2e-local/set-model-endpoint.sh mock
#   tests/e2e-local/set-model-endpoint.sh cpu
#   tests/e2e-local/set-model-endpoint.sh modelservice [NAMESPACE] [NAME]
#   tests/e2e-local/set-model-endpoint.sh url http://host:8000/v1 [MODEL]
set -euo pipefail

MODE="${1:?usage: set-model-endpoint.sh mock|cpu|modelservice|url [...]}"
MODEL="qwen"

case "$MODE" in
mock)
  BASE="http://mock-engine.mock-model.svc.cluster.local:8000/v1" ;;
cpu)
  BASE="http://llamacpp.cpu-model.svc.cluster.local:8000/v1" ;;
modelservice)
  NS="${2:-ml-team}"; NAME="${3:-qwen3-8b}"
  ADDR="$(kubectl get ms "$NAME" -n "$NS" -o jsonpath='{.status.address}' 2>/dev/null || true)"
  if [[ -z "$ADDR" ]]; then
    echo "ModelService $NS/$NAME has no status.address yet." >&2
    echo "It only appears once the gateway is ready and an endpoint is matched:" >&2
    echo "  kubectl get ig default; kubectl get me,ms -n $NS" >&2
    exit 1
  fi
  BASE="${ADDR%/}/v1" ;;
url)
  BASE="${2:?url mode needs a base URL ending in /v1}"; MODEL="${3:-qwen}" ;;
*)
  echo "unknown mode: $MODE" >&2; exit 1 ;;
esac

echo "endpoint: $BASE"
echo "model:    $MODEL"

# Verify from inside the cluster - these are cluster-local addresses that the
# host usually cannot reach.
echo "checking the endpoint answers /v1/models from inside the cluster..."
if kubectl run "endpoint-check-$$" --rm -i --restart=Never --image=curlimages/curl \
     --command -- curl -sf --max-time 20 "${BASE}/models" >/dev/null 2>&1; then
  echo "  ok"
else
  echo "  WARNING: ${BASE}/models did not answer." >&2
  echo "  Writing the Secret anyway, but the operation will fail against it." >&2
fi

kubectl -n crossplane-system delete secret gpt --ignore-not-found
kubectl -n crossplane-system create secret generic gpt \
  --from-literal=OPENAI_API_KEY=not-used-by-local-engines \
  --from-literal=OPENAI_BASE_URL="$BASE" \
  --from-literal=OPENAI_MODEL="$MODEL"

echo
echo "Secret crossplane-system/gpt written. Verify the keys are spelled right -"
echo "a missing OPENAI_BASE_URL silently falls back to api.openai.com:"
echo "  kubectl -n crossplane-system get secret gpt -o jsonpath='{.data}' | \\"
echo "    python3 -c 'import json,sys,base64; print({k: base64.b64decode(v).decode() for k,v in json.load(sys.stdin).items()})'"
