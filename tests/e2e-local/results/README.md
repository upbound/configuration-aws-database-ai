# Recorded model evaluations

Raw output from `tests/e2e-local/eval-model.sh`, kept so the claims in
[`COST.md`](../../COST.md) are checkable rather than asserted.

| Model | Prompt | Correct | Over-scaled | Missed | Verdict |
|---|---|---|---|---|---|
| Qwen2.5-0.5B-Q4 | deployed | 0/24 (0%) | 38% | 0 | not suitable |
| Qwen2.5-1.5B-Q4 | deployed | 4/24 (17%) | **67%** | 0 | not suitable |
| Qwen3-8B-Q4 | deployed | 3/12 (25%) | **75%** | 0 | not suitable |
| Qwen2.5-1.5B-Q4 | v2-fewshot | **19/24 (79%)** | **0%** | 21% | best tested |
| Qwen3-8B-Q4 | v2-fewshot | 8/12 (67%) | 17% | 17% | not suitable |

Served by Modelplane v0.4.0 on the CPU fleet, measured through both routing
paths (raw output: [`v040-incumbent-direct.txt`](v040-incumbent-direct.txt),
[`v040-canary-modelservice.txt`](v040-canary-modelservice.txt)):

| Path | Correct | Over-scaled | Malformed | Unstable |
|---|---|---|---|---|
| incumbent direct, via `ModelEndpoint` | **19/24 (79%)** | **0%** | 0 | 1/12 |
| 90/10 canary, via `ModelService` | 18/24 (75%) | **0%** | 1 | 2/12 |

Two results here, and the first matters more than the second.

**Modelplane's routing costs nothing measurable.** The direct run reproduced the
79% row above *exactly* - same 19/24, same five missed cases, same single
unstable case, same `scale up: cpu 95` flip. The only textual difference from
the earlier standalone-llama.cpp run is which file the prompt was read from, and
those two files are md5-identical. So the `ModelReplica` -> `ModelEndpoint` ->
Envoy path is transparent to decision quality, and the measurement survived a
full teardown and rebuild onto a new Modelplane major version.

**The canary cost exactly one malformed response in 24.** The 75% vs 79% gap is
a single case, `gate: observed fields empty`, where one repeat returned prose
instead of JSON. `prose` is the 0.5B challenger's signature failure - its own
run is full of them and the 1.5B's has none - so the regression is attributable
by failure mode. At a 10% weight, ~2.4 of 24 requests are expected to reach the
challenger, so one or two challenger-attributable results is what the split
predicts. This is the canary working as intended: a bad model is in production
traffic and the damage is bounded to roughly a tenth of it.

**Do not read temperature-0 instability as the canary's fingerprint.** It is
tempting - the canary run shows 2/12 unstable against the direct run's 1/12 -
but the shared unstable case (`scale up: cpu 95`) is unstable *direct too*, with
byte-identical output, and was already unstable in the standalone run before any
canary existed. llama.cpp is not strictly deterministic at temperature 0. Only
the second unstable case is the challenger. Attribute by failure mode, not by
variance.

Sample sizes differ: the 1.5B ran 2 repeats (n=24), the 8B 1 repeat (n=12),
because 8B CPU inference is roughly a minute per request. Read the 8B rows as
indicative, not settled.

**The comparison that matters:**

| | correct | over-scaled |
|---|---|---|
| Qwen2.5-**1.5B** + improved prompt | **79%** | **0%** |
| Qwen3-**8B** + deployed prompt | 25% | 75% |
| Qwen3-**8B** + improved prompt | 67% | 17% |

A 1.5B with a working prompt beat a model five times its size with the shipped
one, decisively - and also beat that model *with* the working prompt. The
honest claim given the sample sizes is that **there is no evidence the 8B is
better at this task**, which is a strong enough result on its own: the ~$860/mo
L4 in `platform/` buys nothing measurable here.

Note *where* the 8B over-scaled: `observed fields empty` and `no metrics` - the
two cases where data is absent. It filled the gap and scaled anyway, while the
smaller model read the rule literally and declined. Larger models being less
willing to refuse on missing input is a plausible and slightly uncomfortable
explanation, and worth testing on more cases before leaning on it.

**No tested configuration is production-clean.** The best result still misses
21% of needed scale-ups.

Temperature 0, 2 repeats per case. The "deployed" prompt is extracted live from
`operations/rds-intelligent-scaling-watch/operation.yaml`, so these cannot drift
from what actually ships.

## What these actually show

**1. Direction of error matters more than accuracy.** 17% correct with 67%
over-scaling is unusable - it spends money on RDS and inverts the entire cost
argument. 79% correct with 0% over-scaling is usable, because the failure is a
slow response rather than a surprise bill. Any quality number quoted without the
direction is close to meaningless.

**2. Going from 0.5B to 1.5B made it more dangerous.** JSON formatting improved,
judgement did not. The smaller model's malformed replies emitted no patch and
were accidentally safe; the larger one confidently emitted well-formed patches
for databases that needed nothing.

**3. Prompting beat model size, decisively.** Same 1.5B, 17% -> 79%, and
over-scaling 67% -> 0%, from two changes: giving the model a legal way to say
"nothing needed" (restate the current class - an identical server-side apply
does not bump `resourceVersion`, so it is still a real no-write), and adding
four worked examples, three of them no-action. The deployed prompt demands
*empty output* for a no-op, which fights how a language model works, and
contains no demonstrations at all.

This is why the first version of this file argued the gates could not live in a
prompt. That was wrong - it was a prompt problem wearing an architecture
problem's clothes.

**4. The deployed prompt fails at every model size tested.** 0.5B, 1.5B and 8B
all score 0 of 9 on the no-action cases with it. What model size *does* buy is
the action cases - the 8B got 3 of 3 right where the 1.5B managed 2 of 6. So
capability and prompt quality are fixing different halves of the problem, and
the prompt is fixing the half that costs money.

**5. What remains is threshold arithmetic, not judgement.** On the improved
prompt the model gets all 9 no-action cases right and only 2 of 6 action
attempts. The misses cluster at the boundary: `CPUUtilization: 81` against a
">80" rule was missed both times, while 95 was caught. So the residual weakness
is numeric comparison near a threshold - the single most trivially deterministic
part of the whole decision.

Which sharpens the follow-up: let code compare the numbers, and ask the model
only for the class. Not because a model cannot reason, but because `81 > 80` is
not a reasoning problem.

The 8B results point the same way from the other end. Across every
configuration tested, the residual failures are exactly two kinds:

1. **numeric comparison near a threshold** - `CPUUtilization: 81` against ">80",
   missed by both models on the improved prompt
2. **declining when required data is absent** - the 8B's only two over-scales

Both are one-line boolean checks. Neither needs a language model, and both are
already computable from data the composition surfaces. That is the whole
argument for a deterministic gate, arrived at from measurement rather than
taste - and note it survives the correction above, where the *first* version of
this argument turned out to be about the prompt.

## Re-running

Mount a shared cache volume. Without it every container re-downloads its
weights, and two concurrent pulls competing for bandwidth is the slowest part of
the whole exercise by a wide margin:

```bash
docker volume create llamacpp-cache

docker run -d --name m --memory 3g -p 18001:8000 \
  -v llamacpp-cache:/root/.cache/llama.cpp \
  ghcr.io/ggml-org/llama.cpp:server \
  -hf Qwen/Qwen2.5-1.5B-Instruct-GGUF:q4_k_m \
  --host 0.0.0.0 --port 8000 --ctx-size 8192 --jinja --temp 0

# deployed prompt
tests/e2e-local/eval-model.sh http://localhost:18001/v1 "" 2
# a variant, for an A/B
tests/e2e-local/eval-model.sh http://localhost:18001/v1 "" 2 \
  tests/e2e-local/prompt-variants/v2-fewshot.yaml

docker rm -f m
```

For a Qwen3 model add `--reasoning off` (the `--chat-template-kwargs
'{"enable_thinking":false}'` form still works but is deprecated). Without it
Qwen3 thinks by default and buries the JSON in a `<think>` block, which fails
to parse.

Budget memory: an 8B at Q4_K_M needs roughly 6 GiB resident. Stopping a local
kind cluster frees more than trimming anything else — `docker stop
<cluster>-control-plane` is reversible with `docker start`.
