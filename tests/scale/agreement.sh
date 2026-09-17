#!/usr/bin/env bash
# Measure how often the self-hosted model reaches the same scaling decision as
# claude-haiku-4-5 on identical inputs.
#
# COST.md prices two options against each other. That comparison is only honest
# if they decide the same things, so this number belongs next to the cost tables.
# It reports agreement plus a breakdown of the disagreements, which matter more
# than the headline: a self-hosted model that is over-eager to scale up costs
# real money in RDS.
#
# Runs in-cluster because the ModelService address is in-cluster. Needs the
# hosted key only for the baseline side:
#   kubectl -n ml-team create secret generic haiku-baseline \
#     --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
#
# Usage: tests/scale/agreement.sh [CASES_JSON]
set -euo pipefail

CASES="${1:-tests/scale/cases.json}"
NS="${MODELSERVICE_NAMESPACE:-ml-team}"
NAME="${MODELSERVICE_NAME:-qwen3-8b}"
BASELINE_MODEL="${BASELINE_MODEL:-claude-haiku-4-5}"
LOCAL_MODEL="${MODEL_NAME:-qwen}"

[[ -f "$CASES" ]] || { echo "no cases file at $CASES" >&2; exit 1; }
ADDRESS="$(kubectl get ms "$NAME" -n "$NS" -o jsonpath='{.status.address}')"
[[ -n "$ADDRESS" ]] || { echo "ModelService $NS/$NAME has no address" >&2; exit 1; }

kubectl run "agreement-$$" -n "$NS" --rm -i --restart=Never \
  --image=python:3.12-alpine \
  --env="ADDRESS=$ADDRESS" \
  --env="LOCAL_MODEL=$LOCAL_MODEL" \
  --env="BASELINE_MODEL=$BASELINE_MODEL" \
  --env="CASES=$(cat "$CASES")" \
  --overrides='{"spec":{"containers":[{"name":"agreement-'"$$"'","image":"python:3.12-alpine","stdin":true,"tty":false,"env":[{"name":"ANTHROPIC_API_KEY","valueFrom":{"secretKeyRef":{"name":"haiku-baseline","key":"ANTHROPIC_API_KEY"}}}]}]}}' \
  -- python -u -c '
import json, os, re, urllib.request

cases = json.loads(os.environ["CASES"])
local_url = os.environ["ADDRESS"].rstrip("/") + "/v1/chat/completions"
key = os.environ.get("ANTHROPIC_API_KEY", "")

# Keep in sync with operations/rds-intelligent-scaling-watch/operation.yaml.
PROMPT = """You are an RDS scaling controller. Reply with a single JSON object or nothing.
If no change is needed output NOTHING AT ALL. Otherwise output one line of JSON:
{"apiVersion":"aws.platform.upbound.io/v1alpha1","kind":"SQLInstance","metadata":{"name":"N","namespace":"NS"},"spec":{"parameters":{"instanceClass":"C"}}}
Output nothing if status.observedInstanceClass differs from spec.parameters.instanceClass,
or status.observedInstanceStatus is not "available", or metrics are missing.
Scale UP one step when CPUUtilization > 80, connections > 80% of limit, or free memory < 15%.
Scale DOWN one step only when CPUUtilization < 20 AND connections < 30% AND free memory > 60%.
Steps: db.t3.micro -> db.t3.small -> db.t3.medium -> db.t3.large
No markdown fences. Resource:
"""

def ask(url, model, resource, hosted):
    """Query one model. The self-hosted side speaks OpenAI chat-completions,
    which is what function-openai calls. The Haiku baseline speaks the Anthropic
    Messages API - Anthropic is not OpenAI-compatible, so the two sides
    genuinely need different request and response shapes."""
    body = {"model": model, "max_tokens": 512, "temperature": 0,
            "messages": [{"role": "user", "content": PROMPT + json.dumps(resource)}]}
    if hosted:
        h = {"content-type": "application/json",
             "anthropic-version": "2023-06-01", "x-api-key": key}
    else:
        h = {"content-type": "application/json",
             "authorization": "Bearer not-used-by-vllm"}
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h)
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.load(r)
    if hosted:
        return "".join(b.get("text", "") for b in d.get("content") or [])
    ch = (d.get("choices") or [{}])[0]
    return (ch.get("message") or {}).get("content") or ""

def decision(text):
    """Normalize a reply to the decision it represents."""
    t = re.sub(r"^```(?:json)?|```$", "", text.strip(), flags=re.M).strip()
    if not t:
        return ("noop", None)
    try:
        return ("scale", json.loads(t)["spec"]["parameters"]["instanceClass"])
    except Exception:
        return ("unparseable", t[:80])

agree = 0
rows = []
for c in cases:
    want_note = c.get("note", "")
    res = c["resource"]
    a = decision(ask(local_url, os.environ["LOCAL_MODEL"], res, False))
    b = decision(ask("https://api.anthropic.com/v1/messages",
                     os.environ["BASELINE_MODEL"], res, True)) if key else ("skipped", None)
    same = a == b
    agree += same
    rows.append((want_note, a, b, same))

print(f"{'case':<34} {'self-hosted':<22} {'haiku':<22} match")
for note, a, b, same in rows:
    print(f"{note[:33]:<34} {str(a)[:21]:<22} {str(b)[:21]:<22} {'yes' if same else 'NO'}")
print()
print(f"agreement: {agree}/{len(rows)} = {100*agree/max(1,len(rows)):.0f}%")
bad = [r for r in rows if not r[3]]
if bad:
    print("\ndisagreements (the interesting part):")
    for note, a, b, _ in bad:
        print(f"  {note}: self-hosted={a} haiku={b}")
'
