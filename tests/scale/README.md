# Scale and cost measurement

`COST.md` makes an economic argument from a mix of measured and estimated
numbers. Everything in it marked ESTIMATE is a placeholder these harnesses are
meant to replace. Until then the conclusions are directional, not evidence.

Three tracks, deliberately separate, because they fail for different reasons and
answer different questions.

## 1. Raw model throughput — `bench-modelservice.sh`

Hits the ModelService directly, no Crossplane in the path. Answers: how many
decisions per second does one L4 actually sustain, at what latency, and how many
tokens does a real decision cost?

```bash
for c in 1 8 32 128; do tests/scale/bench-modelservice.sh "$c" 200; done
```

Reports decisions/sec, decisions/month, p50/p95/p99, mean tokens in/out, and the
no-op reply count. **The decisions/month figure directly replaces the
~1.0–1.7M/mo estimate in COST.md.**

Run it twice — once on FP16 `Qwen/Qwen3-8B` and once on `Qwen/Qwen3-8B-AWQ` — to
settle the open question in COST.md about which shape to serve. Weights drop from
~16 GB to ~6 GB on an L4's 23 GB, and the freed VRAM becomes KV cache, which is
what caps concurrency.

## 2. Decision quality — `agreement.sh`

```bash
kubectl -n ml-team create secret generic haiku-baseline \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY"
tests/scale/agreement.sh tests/scale/cases.json
```

Replays the 12 cases in `cases.json` through both the self-hosted model and
`claude-haiku-4-5` and reports agreement plus every disagreement.

**This is the honesty check.** COST.md prices two options against each other;
that is only meaningful if they decide the same things. Five of the twelve cases
are gates rather than thresholds — change-in-flight, modifying, empty observed
fields, already-at-largest, already-at-smallest — because those are where a
wrong answer either loops or costs real RDS money. Read the disagreements, not
just the percentage: a model that is over-eager to scale *up* is expensive in a
way the headline number hides.

## 3. Control-plane behaviour at fleet scale — `synthetic-fleet.sh`

```bash
tests/scale/synthetic-fleet.sh 500 --seed-metrics
# ... observe ...
tests/scale/synthetic-fleet.sh --delete
```

`managementPolicies: [Observe]` means nothing is created in AWS, so a 500-strong
fleet costs nothing. What it exercises is the part that actually strains:
WatchOperation fan-out, one Operation per resource, API server and Operation GC
churn, and GPU saturation under concurrent real decisions.

Note the caveat in the script header: without real RDS there is no CloudWatch
data, so unseeded XRs measure the no-op path. `--seed-metrics` patches status
directly; confirm the metrics function does not immediately overwrite it in your
setup.

### The test that matters most

Loop stability. The design rests on a no-op writing *nothing*, because any write
mutates the watched resource and the generated Operation's name hashes its
resourceVersion — so a no-op that writes an annotation re-triggers itself
forever.

```bash
# lastScheduleTime must STOP advancing. Counting Operation objects does not
# work: successfulHistoryLimit (3) GCs them, so the count pins at 3 whether the
# loop has settled or is spinning.
for i in $(seq 1 10); do
  kubectl get watchoperation rds-intelligent-scaling \
    -o jsonpath='{.status.lastScheduleTime}{"\n"}'
  sleep 60
done
```

**`lastScheduleTime` must stop advancing** on an idle fleet. If it keeps
advancing, something on the no-op path is still writing, and the whole
event-driven design is unsafe.

Measured this the obvious way and it silently tells you nothing:
`successfulHistoryLimit: 3` garbage-collects Operations, so
`kubectl get operation | wc -l` sits at 3 whether the loop has settled or is
spinning as fast as the model will answer. The Operation *names* rotate; the
count never moves.

The harder problem is the opposite failure. `function-openai` does **not** strip
markdown fences on the operation path (only the composition path does), and a
parse failure is logged at debug while still reporting `FunctionSuccess=True`
with no desired resources. So a model that has drifted into fenced output looks
*exactly* like a fleet where nothing needs scaling. Under load, verify scale-ups
actually happen rather than trusting a quiet Operation log:

```bash
kubectl get sqlinstance -n database-team -o custom-columns=\
NAME:.metadata.name,WANT:.spec.parameters.instanceClass,GOT:.status.observedInstanceClass
```

Porting the fence-stripping and an explicit failure condition into
`function-openai`'s operation path would make this observable rather than
inferred, and is the highest-value follow-up in this repo.

## Verifying the convergence gate without a cluster

```bash
up composition render --xrd=apis/definition.yaml \
  apis/composition-rds-metrics.yaml \
  examples/mariadb-xr-rds-metrics.yaml \
  --function-credentials=tests/test-credentials.yaml \
  --observed-resources=tests/fixtures/observed-rds-instance.yaml
```

Expect `status.observedInstanceClass` and `status.observedInstanceStatus` on the
rendered XR. Those are what the prompt compares against
`spec.parameters.instanceClass`.
