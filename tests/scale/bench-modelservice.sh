#!/usr/bin/env bash
# Measure raw decision throughput against the Modelplane ModelService, with no
# Crossplane in the path. This is what replaces the throughput ESTIMATE in
# COST.md: decisions/sec, latency percentiles, and observed token counts.
#
# The ModelService address is in-cluster, so this runs as a Job inside the
# control plane cluster rather than from your laptop.
#
# Usage:
#   tests/scale/bench-modelservice.sh [CONCURRENCY] [REQUESTS]
# Example sweep:
#   for c in 1 8 32 128; do tests/scale/bench-modelservice.sh "$c" 200; done
set -euo pipefail

CONCURRENCY="${1:-8}"
REQUESTS="${2:-200}"
NS="${MODELSERVICE_NAMESPACE:-ml-team}"
NAME="${MODELSERVICE_NAME:-qwen3-8b}"
MODEL="${MODEL_NAME:-qwen}"

ADDRESS="$(kubectl get ms "$NAME" -n "$NS" -o jsonpath='{.status.address}')"
if [[ -z "$ADDRESS" ]]; then
  echo "ModelService $NS/$NAME has no status.address yet." >&2
  exit 1
fi
echo "address=$ADDRESS concurrency=$CONCURRENCY requests=$REQUESTS"

# A representative prompt. Keep this in sync with the WatchOperation's prompt or
# the token counts measured here will not match production.
read -r -d '' PROMPT <<'PROMPT_EOF' || true
You are an RDS scaling controller. Reply with a single JSON object or nothing.
Decide whether this SQLInstance needs its instance class changed. If no change
is needed output NOTHING AT ALL. Otherwise output one line of JSON:
{"apiVersion":"aws.platform.upbound.io/v1alpha1","kind":"SQLInstance","metadata":{"name":"N","namespace":"NS"},"spec":{"parameters":{"instanceClass":"C"}}}
Change nothing if status.observedInstanceClass differs from
spec.parameters.instanceClass, or observedInstanceStatus is not "available".
Scale up one step when CPUUtilization > 80. Steps:
db.t3.micro -> db.t3.small -> db.t3.medium -> db.t3.large
Resource:
{"apiVersion":"aws.platform.upbound.io/v1alpha1","kind":"SQLInstance","metadata":{"name":"bench-db","namespace":"database-team"},"spec":{"parameters":{"instanceClass":"db.t3.micro","engine":"mariadb","region":"us-west-2","storageGB":5}},"status":{"observedInstanceClass":"db.t3.micro","observedInstanceStatus":"available","performanceMetrics":{"metrics":{"CPUUtilization":{"value":94.2,"unit":"Percent"},"DatabaseConnections":{"value":12,"unit":"Count"},"FreeableMemory":{"value":41000000,"unit":"Bytes"},"FreeStorageSpace":{"value":2775404544,"unit":"Bytes"},"ReadIOPS":{"value":180,"unit":"Count/Second"},"WriteIOPS":{"value":95,"unit":"Count/Second"}}}}}
PROMPT_EOF

# The OpenAI chat-completions route, which is what function-openai calls. With
# no MCP tools configured langchaingo omits "tools" from the request entirely
# (it is json:"tools,omitempty"), so this is a plain completion and the engine
# needs no tool-calling flags.
BODY="$(MODEL="$MODEL" python3 -c '
import json,os,sys
print(json.dumps({
  "model": os.environ["MODEL"],
  "max_tokens": 512,
  "temperature": 0,
  "messages": [{"role":"user","content":sys.stdin.read()}],
}))' <<<"$PROMPT")"

kubectl run "bench-$$" -n "$NS" --rm -i --restart=Never \
  --image=python:3.12-alpine \
  --env="ADDRESS=$ADDRESS" --env="CONCURRENCY=$CONCURRENCY" \
  --env="REQUESTS=$REQUESTS" --env="BODY=$BODY" \
  -- python -u -c '
import json, os, statistics, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

url  = os.environ["ADDRESS"].rstrip("/") + "/v1/chat/completions"
body = os.environ["BODY"].encode()
n    = int(os.environ["REQUESTS"]); c = int(os.environ["CONCURRENCY"])
lat, toks, errs, empties = [], [], 0, 0

def one(_):
    t0 = time.perf_counter()
    req = urllib.request.Request(url, data=body, headers={
        "content-type": "application/json",
        # function-openai always sends a bearer token; vLLM ignores it.
        "authorization": "Bearer not-used-by-vllm",
    })
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.load(r)
    return time.perf_counter() - t0, d

start = time.perf_counter()
with ThreadPoolExecutor(max_workers=c) as ex:
    for r in ex.map(lambda i: (lambda: one(i))(), range(n)):
        try:
            dt, d = r
        except Exception:
            errs += 1; continue
        lat.append(dt)
        u = d.get("usage") or {}
        toks.append((u.get("prompt_tokens", 0), u.get("completion_tokens", 0)))
        ch = (d.get("choices") or [{}])[0]
        text = (ch.get("message") or {}).get("content") or ""
        if not text.strip():
            empties += 1
wall = time.perf_counter() - start

if not lat:
    print("all requests failed"); raise SystemExit(1)
lat.sort()
p = lambda q: lat[min(len(lat)-1, int(len(lat)*q))]
print(f"concurrency      {c}")
print(f"completed        {len(lat)}/{n}  errors={errs}")
print(f"wall             {wall:.1f}s")
print(f"decisions/sec    {len(lat)/wall:.2f}")
print(f"decisions/month  {len(lat)/wall*3600*24*30:,.0f}   <- replaces the COST.md estimate")
print(f"latency p50/p95/p99  {p(.50):.2f}s / {p(.95):.2f}s / {p(.99):.2f}s")
print(f"mean tokens in/out   {statistics.mean(t[0] for t in toks):.0f} / {statistics.mean(t[1] for t in toks):.0f}")
print(f"empty (no-op) replies {empties}/{len(lat)}")
'
