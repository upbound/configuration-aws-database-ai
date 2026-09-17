#!/usr/bin/env bash
# Evaluate a candidate model against the real scaling prompt and the real gate
# cases, and report how often it produces a usable decision.
#
# This is the question the mock cannot answer: the mock proves the contract
# holds, this proves a given model can satisfy it. Run it before committing to a
# model for the acceptance demo - "it is only picking one of four instance
# classes" badly understates the task, because the reply must ALSO be exact JSON
# with no fences, copy two identifiers verbatim, and respect five gates.
#
# Talks to any OpenAI-compatible endpoint, so it works against llama.cpp on a
# laptop, a Modelplane ModelService, or a hosted provider.
#
# Usage:
#   tests/e2e-local/eval-model.sh http://localhost:18000/v1 [MODEL] [REPEATS]
set -euo pipefail

BASE="${1:?usage: eval-model.sh BASE_URL [MODEL] [REPEATS] [PROMPT_FILE]}"
MODEL="${2:-}"
REPEATS="${3:-3}"
# Any YAML carrying "systemPrompt: |" and "userPrompt: |" blocks. Defaults to
# the live operation, so by default this measures what is actually deployed.
# Point it at tests/e2e-local/prompt-variants/*.yaml to compare prompts.
PROMPT_FILE="${4:-}"

if [[ -z "$MODEL" ]]; then
  # llama.cpp answers /v1/models with {"models":[...]} rather than OpenAI's
  # {"data":[...]}, so accept either shape.
  MODEL="$(curl -sf "${BASE}/models" | python3 -c '
import json,sys
d = json.load(sys.stdin)
items = d.get("data") or d.get("models") or []
print((items[0].get("id") or items[0].get("model") or items[0].get("name")) if items else "")')"
fi
echo "endpoint: $BASE"
echo "model:    $MODEL"
echo "repeats:  $REPEATS per case (temperature 0, so variance means instability)"
echo

[[ -z "$PROMPT_FILE" ]] && PROMPT_FILE="$(dirname "$0")/../../operations/rds-intelligent-scaling-watch/operation.yaml"
echo "prompt:   $PROMPT_FILE"

BASE="$BASE" MODEL="$MODEL" REPEATS="$REPEATS" \
CASES="$(cat "$(dirname "$0")/../scale/cases.json")" \
PROMPT_SRC="$PROMPT_FILE" \
python3 - <<'PY'
import json, os, re, urllib.request, collections

base, model, repeats = os.environ["BASE"].rstrip("/"), os.environ["MODEL"], int(os.environ["REPEATS"])
cases = json.loads(os.environ["CASES"])

# Use the real prompt, extracted from the operation, so this measures what is
# actually deployed rather than a paraphrase that drifts out of sync.
def block(raw, key):
    """Pull a YAML literal block by key, dedenting from its own indentation.

    Indentation-driven rather than hardcoded, so the same extractor works on the
    operation manifest and on standalone prompt-variant files.
    """
    lines = raw.split("\n")
    for i, l in enumerate(lines):
        if l.strip() == f"{key}: |":
            base = len(l) - len(l.lstrip())
            out = []
            for nxt in lines[i + 1:]:
                if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= base:
                    break
                out.append(nxt[base + 2:] if len(nxt) > base + 2 else "")
            return "\n".join(out).rstrip()
    raise SystemExit(f"no '{key}: |' block in {os.environ['PROMPT_SRC']}")

raw = open(os.environ["PROMPT_SRC"]).read()
system, user = block(raw, "systemPrompt"), block(raw, "userPrompt")
if "{{ .Resources }}" not in user:
    raise SystemExit("userPrompt has no {{ .Resources }} placeholder")
print(f"          system={len(system)}ch user={len(user)}ch\n")

def ask(resource):
    body = json.dumps({
        "model": model, "max_tokens": 512, "temperature": 0,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": user.replace("{{ .Resources }}", json.dumps(resource, indent=4, sort_keys=True))}],
    }).encode()
    req = urllib.request.Request(f"{base}/chat/completions", data=body, headers={
        "content-type": "application/json", "authorization": "Bearer not-used"})
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.load(r)
    return ((d.get("choices") or [{}])[0].get("message") or {}).get("content") or ""

def classify(text, res):
    """What did the model actually produce?"""
    t = text.strip()
    if not t:
        return "noop", None
    fenced = t.startswith("```")
    t2 = re.sub(r"^```(?:json)?|```$", "", t, flags=re.M).strip()
    try:
        d = json.loads(t2)
    except Exception:
        return ("fenced-unparseable" if fenced else "prose"), t[:60]
    try:
        cls = d["spec"]["parameters"]["instanceClass"]
    except Exception:
        return "json-wrong-shape", t2[:60]
    meta = d.get("metadata") or {}
    want_meta = res["metadata"]
    if meta.get("name") != want_meta["name"] or meta.get("namespace") != want_meta.get("namespace"):
        return "wrong-identity", f"{meta.get('name')}/{meta.get('namespace')}"
    # Under the "legal no-op" contract the model restates the CURRENT class to
    # mean "nothing needed". A server-side apply of identical content does not
    # bump resourceVersion, so that is a genuine no-write - and it gives the
    # model a sanctioned way to answer, instead of demanding it emit nothing,
    # which is what a language model is least willing to do.
    current = ((res.get("spec") or {}).get("parameters") or {}).get("instanceClass")
    if cls == current and not (meta.get("annotations") or {}):
        return "noop-explicit", cls
    return ("scale-fenced" if fenced else "scale"), cls

def verdict(kind, cls, want):
    """Score the DECISION, not just the format.

    Format compliance and correctness are different things, and conflating them
    flatters a model badly: one that emits perfect JSON saying "scale up" for
    every input scores 100% on format and is worse than useless.

    Direction matters for cost. Scaling up when the answer was no-op spends real
    money on RDS; failing to scale up only forgoes a benefit. So over-scaling is
    reported separately rather than lumped into one error rate.
    """
    if want == "noop":
        if kind in ("noop", "noop-explicit"):
            return "correct"
        if kind in ("scale", "scale-fenced"):
            return "OVER-SCALED"      # costs money
        return "malformed"            # no patch, so accidentally safe
    # want is a target instance class
    if kind in ("noop", "noop-explicit"):
        return "missed"               # forgoes a benefit, does not cost money
    if kind in ("scale", "scale-fenced"):
        return "correct" if cls == want else "wrong-class"
    return "malformed"

tally = collections.Counter()
verdicts = collections.Counter()
rows = []
for c in cases:
    res, note, want = c["resource"], c.get("note", ""), c.get("expect", "?")
    outs = [classify(ask(res), res) for _ in range(repeats)]
    kinds = [o[0] for o in outs]
    vs = [verdict(k, cl, want) for k, cl in outs]
    tally.update(kinds)
    verdicts.update(vs)
    rows.append((note, want, kinds, vs, len(set(kinds)) == 1))

print(f"{'case':<34} {'expected':<14} {'got':<30} verdict")
for note, want, kinds, vs, stable in rows:
    mark = "" if stable else "  (unstable)"
    print(f"{note[:33]:<34} {want:<14} {','.join(kinds)[:29]:<30} "
          f"{','.join(sorted(set(vs)))}{mark}")

total = sum(verdicts.values())
print("\nverdicts:")
for k, v in verdicts.most_common():
    print(f"  {k:<14} {v:>3}  ({100*v/total:.0f}%)")

print(f"\nCORRECT DECISIONS: {verdicts['correct']}/{total} = "
      f"{100*verdicts['correct']/total:.0f}%")
if verdicts["OVER-SCALED"]:
    print(f"  OVER-SCALED {verdicts['OVER-SCALED']} times - this is the expensive failure. "
          f"It scales a database that did not need it.")
if verdicts["malformed"]:
    print(f"  malformed {verdicts['malformed']} - no patch emitted, so safe but useless")
if tally["scale-fenced"] or tally["fenced-unparseable"]:
    print(f"  fenced {tally['scale-fenced'] + tally['fenced-unparseable']} "
          f"- DISCARDED SILENTLY by function-openai's operation path")
if tally["wrong-identity"]:
    print(f"  wrong identity {tally['wrong-identity']} - patches nothing, or the wrong database")
unstable = sum(1 for r in rows if not r[4])
if unstable:
    print(f"  {unstable}/{len(rows)} cases differed across repeats at temperature 0")

print("\nVerdict on this model for the acceptance demo:")
rate = 100 * verdicts["correct"] / total
over = verdicts["OVER-SCALED"]
miss = verdicts["missed"]
# Direction of error matters more than the rate. Over-scaling spends money on
# RDS and inverts the whole cost argument; missing a scale-up only forgoes a
# benefit and leaves the database exactly as the operator provisioned it. A
# conservative model is usable; an aggressive one is not, at any accuracy.
if over:
    print(f"  NOT SUITABLE - over-scales {100*over/total:.0f}% of the time, which "
          f"costs money and inverts the cost argument.")
elif rate >= 95:
    print("  Suitable.")
elif rate >= 75:
    print(f"  USABLE WITH CARE - {rate:.0f}% correct and errs conservatively "
          f"({miss} missed, 0 over-scaled).")
    print("  It under-reacts rather than over-reacts, so the failure mode is a")
    print("  slow response, not a surprise bill. Fine for a demo; pair it with a")
    print("  deterministic threshold check if you want the missed cases caught.")
else:
    print(f"  NOT SUITABLE - only {rate:.0f}% correct.")
PY
