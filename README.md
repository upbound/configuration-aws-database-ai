# AWS Database Configuration

This repository contains an Upbound project, tailored for users establishing their initial control plane with [Upbound](https://cloud.upbound.io). This configuration deploys fully managed AWS database instances.

## Overview

The core components of a custom API in [Upbound Project](https://docs.upbound.io/learn/control-plane-project/) include:

- **CompositeResourceDefinition (XRD):** Defines the API's structure.
- **Composition(s):** Configures the Functions Pipeline
- **Embedded Function(s):** Encapsulates the Composition logic and implementation within a self-contained, reusable unit

In this specific configuration, the API contains:

- **an [AWS Database](/apis/definition.yaml) custom resource type (v2 namespaced).**
- **Composition:** Configured in [/apis/composition-rds-metrics.yaml](/apis/composition-rds-metrics.yaml)
- **Embedded Function:** The Composition logic is encapsulated within [embedded function](/functions/sqlinstance/main.k)

Beyond the composition itself:

| Path | What it is |
|---|---|
| [`platform/`](/platform/) | Modelplane inference platform - the GPU cluster and model that serve scaling decisions |
| [`platform/cpu-fleet/`](/platform/cpu-fleet/) | The same thing with no GPU - Modelplane deploying and canarying two CPU models on a laptop |
| [`operations/`](/operations/) | The `WatchOperation` that reacts to metric changes |
| [`COST.md`](/COST.md) | The economic argument, with assumptions stated and estimates labelled |
| [`tests/e2e-local/`](/tests/e2e-local/) | Free end-to-end rigs — a scriptable mock engine, a CPU model, and a model evaluator |
| [`tests/scale/`](/tests/scale/) | Throughput, decision-quality and fleet-scale measurement |

## Intelligent RDS Scaling with Crossplane Operations

Scaling decisions are made by a model we host ourselves, on a
[Modelplane](https://github.com/modelplaneai/modelplane) inference cluster, and
they are triggered by change rather than by a timer.

That second part is the point. The previous design ran a `CronOperation` every
minute against a hosted model. The schedule was never a design choice - it was a
rate limiter for API spend, and so was the annotation-age arithmetic that used to
live in the prompt. Serving the model ourselves removes the marginal cost per
decision, which removes the reason for both. The interesting consequence is not a
smaller bill at the old cadence; it is that **responsiveness stops costing
money**. See [COST.md](COST.md) for where that crosses over.

### Architecture

**Pipeline flow**: `RDS → CloudWatch → XR status → WatchOperation → self-hosted model → patch`

```
┌─────────────────┐    ┌──────────────────┐
│   RDS Instance  │───▶│ function-rds-    │───▶ status.performanceMetrics
│   (CloudWatch)  │    │    metrics       │     status.observedInstanceClass
└─────────────────┘    └──────────────────┘     status.observedInstanceStatus
                                                      │
                                          any change to the XR
                                                      │
                                                      ▼
                                        ┌─────────────────────────┐
                                        │ WatchOperation          │
                                        │ one Operation per       │
                                        │ changed resource        │
                                        │                         │
                                        │ function-openai         │
                                        │   OPENAI_BASE_URL ──┐   │
                                        └─────────────────────┼───┘
                                                      │       │
                                                      │       ▼
                                                      │  ┌─────────────────────────┐
                                                      │  │ Modelplane              │
                                                      │  │ ModelService            │
                                                      │  │ vLLM /v1/chat/          │
                                                      │  │      completions        │
                                                      │  │ Qwen3-8B on 1x L4       │
                                                      │  └─────────────────────────┘
                                                      ▼
                                        ┌─────────────────────────┐
                                        │ patch instanceClass     │
                                        │ + reasoning annotation  │
                                        │ ...or write nothing     │
                                        └─────────────────────────┘
```

`function-openai` reads its endpoint, model and token from a credential Secret
(`OPENAI_BASE_URL`, `OPENAI_MODEL`, `OPENAI_API_KEY`), so **no fork or patched
function is needed** - it does this out of the box. Point it at the Modelplane
`ModelService` address and these decisions run on our own hardware; point it at
any other OpenAI-compatible provider and they run there instead. Either way it
is a Secret edit, not a manifest change.

Two details make a small model workable here. With no MCP tools configured,
langchaingo omits `tools` from the request entirely, so this is a plain chat
completion and the engine needs no tool-calling flags. And in that case the
agent returns the model's content **verbatim** rather than demanding a formatted
`Final Answer:`, which is the failure mode that makes ReAct-style wrappers
fragile on smaller models.

### Component integration

**Composition** (`apis/composition-rds-metrics.yaml`)
- **function-rds-metrics** writes CloudWatch data to `status.performanceMetrics`
- **the embedded KCL function** composes the SubnetGroup, Instance and connection
  Secret, and surfaces `status.observedInstanceClass` /
  `status.observedInstanceStatus` from the RDS instance
- **function-auto-ready** marks the composition ready

There is deliberately **no model in the composition pipeline.** Inference happens
in an Operation, so a slow or unavailable model cannot block reconciliation.

**WatchOperation** (`operations/rds-intelligent-scaling-watch/operation.yaml`)
- fires on any change to a `SQLInstance` labelled `scale: me`, in any namespace
- **function-openai**, with the endpoint and model supplied by the `gpt` Secret
- `concurrencyPolicy: Forbid`, so a burst of metric updates cannot stack racing
  decisions on one database

**Platform** (`platform/`) - the Modelplane prerequisites, inference class,
cluster, model deployment and service. These are platform-team concerns; this
configuration consumes an endpoint, it does not provision GPUs.

### The three problems this design has to solve

**1. The loop must settle.** A `WatchOperation` reacts to change, and the
generated Operation's name hashes the watched resource's `resourceVersion`. So
*any* write re-triggers the analysis. A no-op that stamps a "last analyzed"
annotation - which is what the old prompt did - would run forever. The prompt's
first and most emphasised rule is therefore that no action means **no output at
all**. An empty reply fails `resourceFrom`, which yields no desired resources,
so nothing is written and the loop settles.

**2. The model has no clock.** The old prompt asked it to read a timestamp
annotation, compute elapsed seconds, and emit the current time in ISO8601. None
of that is possible. Thrash prevention instead compares two strings the
composition provides: while `status.observedInstanceClass` differs from
`spec.parameters.instanceClass`, a change is already in flight and no new
decision is made.

**3. A smaller model drifts off-format more often.** The engine runs with
`--reasoning-parser=qwen3` and thinking disabled, because Qwen3 thinks by
default and would bury the JSON in a `<think>` block.

One gap to know about: `function-openai` strips markdown fences only on its
*composition* path, not the operation path its `resourceFrom` uses. So a reply
wrapped in ```` ```json ```` fences fails to parse, and it fails **silently** -
logged at debug, still reported `FunctionSuccess=True`, with no desired
resources. That is why the prompt's no-fences rule is stated as forcefully as
the decision rules themselves, and why `tests/scale/` measures the parse-failure
rate. Porting the fence-stripping and a failure condition into the operation
path is the obvious follow-up.

### Decision process

**Input**: CloudWatch metrics plus the two convergence-gate fields.

```yaml
status:
  observedInstanceClass: db.t3.micro     # what RDS reports
  observedInstanceStatus: available      # gate: must be "available"
  performanceMetrics:
    metrics:
      CPUUtilization: {value: 94.2, unit: "Percent"}
      DatabaseConnections: {value: 12, unit: "Count"}
      FreeableMemory: {value: 41000000, unit: "Bytes"}
```

**Gates checked first.** Any one of these means no output: a change already in
flight, instance not `available`, observed fields missing, metrics missing,
already at the smallest or largest class.

**Thresholds.** Up one step on CPU >80%, connections >80% of limit, or free
memory <15%. Down one step only when CPU <20% **and** connections <30% **and**
free memory >60%. Steps:
`db.t3.micro → db.t3.small → db.t3.medium → db.t3.large`

**Output**: either nothing at all, or one line of JSON patching the class and
recording why.

```json
{"apiVersion":"aws.platform.upbound.io/v1alpha1","kind":"SQLInstance","metadata":{"name":"my-db","namespace":"database-team","annotations":{"intelligent-scaling/reasoning":"CPU 94% sustained above 80%"}},"spec":{"parameters":{"instanceClass":"db.t3.small"}}}
```

The audit trail is the annotation on real scaling events plus the retained
Operation objects, which carry the decision text as an event. There is no
`status.claudeDecision` - that field was declared but never written, and status
is a subresource an Operation patch cannot reach.

### Cost

The economic argument is the reason this exists, so it has its own document with
its assumptions stated and its estimates labelled: **[COST.md](COST.md)**.

The short version, at roughly $0.00475 per hosted decision against ~$860/mo for
one L4:

| Cadence | Break-even fleet | Databases per L4 |
|---|---|---|
| every 10 min | ~42 | ~300 |
| every 1 min | ~4 | ~30 |
| every 10 s | 1 | ~5 |

Sub-15-second reactive scaling is economically out of reach on a hosted frontier
model at any fleet size, and merely expensive on your own hardware. And at 1,000
databases the hosted decision layer costs several times more than the
over-provisioning it exists to eliminate.

> **The throughput figures behind those numbers are still estimates.**
> `tests/scale/` exists to replace them, including a decision-agreement
> measurement against `claude-haiku-4-5` - without which pricing the two options
> against each other is not honest.
### Usage
Deploy an intelligent scaling database:
```yaml
apiVersion: aws.platform.upbound.io/v1alpha1
kind: SQLInstance
metadata:
  name: my-intelligent-db
  namespace: default
  labels:
    scale: me  # opts this database into the scaling WatchOperation
spec:
  crossplane:
    compositionSelector:
      matchLabels:
        type: rds-metrics
  parameters:
    engine: mariadb
    engineVersion: "10.11"
    storageGB: 20
    region: us-west-2
    networkRef:
      id: my-network
    passwordSecretRef:
      name: my-db-password
      key: password
    # ... other parameters
```

### Prerequisites

1. **A Crossplane control plane at v2.3.0 or later**, installed with
   `--set-json 'provider.defaultActivations=[]'`. Modelplane's
   `ModelDeployment` XRD uses the scale subresource, which XRDs only support
   from v2.3, and its `ManagedResourceActivationPolicy` governs which managed
   resources are active.

2. **The Modelplane platform**, applied in order:
   ```bash
   kubectl apply -f platform/00-prerequisites.yaml
   kubectl apply -f platform/10-configuration.yaml
   # wait for the Configuration to become healthy, then:
   kubectl apply -f platform/
   ```
   The inference cluster takes a while: it provisions EKS, a GPU node group, and
   the serving stack. Watch it with
   `kubectl get inferencecluster,modeldeployment,modelservice -A`.

3. **The ModelService address**, which you will need for the Secret in step 4.
   It only appears once the deployment is serving:
   ```bash
   kubectl get ms qwen3-8b -n ml-team -o jsonpath='{.status.address}'
   ```
   Nothing in `operations/` needs editing - the endpoint lives in the Secret.

4. **The `gpt` credential Secret**, which carries the endpoint and model as well
   as the token. `function-openai` supports this out of the box - no patched
   function required:
   ```bash
   kubectl -n crossplane-system create secret generic gpt \
     --from-literal=OPENAI_API_KEY=not-used-by-vllm \
     --from-literal=OPENAI_BASE_URL="$(kubectl get ms qwen3-8b -n ml-team \
        -o jsonpath='{.status.address}')/v1" \
     --from-literal=OPENAI_MODEL=qwen
   ```
   `OPENAI_API_KEY` is required but unchecked by vLLM. `OPENAI_MODEL` must match
   the engine's `--served-model-name`.

   > **Check this Secret first if anything looks wrong.** `OPENAI_BASE_URL`
   > defaults to `api.openai.com` and `OPENAI_MODEL` to `gpt-4`, so a missing or
   > misspelled key sends these decisions to OpenAI instead of failing.

   The credential name `gpt` and the key `OPENAI_API_KEY` are compiled into the
   function, so neither is configurable.

5. **AWS credentials** in `crossplane-system/aws-creds` for CloudWatch access.

> **Topology constraint.** Modelplane serves its gateway over plain HTTP with no
> authentication and no TLS. The WatchOperation must therefore run on the same
> cluster as the InferenceGateway so the endpoint is never exposed. Do not put
> the control plane and the model on different networks and bridge them over the
> internet.

**Current status: experimental.** The wiring is verified and the composition
renders, but the cost model still rests on estimates and the decision-quality
comparison in `tests/scale/` has not been run.

## Performance Testing (perftest)

### How to Run Performance Tests

This repository includes automated scripts to validate the intelligent scaling system and trigger AI-driven scaling decisions.

#### Automated Load Test with Monitoring

Use `perf-scale-demo.sh` for a complete end-to-end scaling demonstration:

```bash
# Run with defaults (rds-metrics-database-ai-mysql in database-team namespace)
./perf-scale-demo.sh

# Custom SQLInstance name
./perf-scale-demo.sh my-database

# Custom SQLInstance and namespace
./perf-scale-demo.sh my-database default
```

**What it does**:
- Automatically extracts connection details from the SQLInstance's connection secret
- Launches 30 concurrent MySQL processes with intensive CPU load (BENCHMARK operations)
- Monitors CPU utilization, instance class, and scaling decisions every 20 seconds
- Automatically stops when scaling is detected or after 5 minutes
- Cleans up all background processes on completion

**Expected timeline**:
1. 30-60 seconds: CPU reaches 50%+ utilization
2. 1-2 minutes: CloudWatch metrics update
3. Seconds: the metric change triggers a WatchOperation, the self-hosted model
   decides, and instanceClass is patched
4. 5-10 minutes: the RDS instance class change completes

#### Continuous Monitoring

Use `simple-demo-scaling-monitor.sh` to watch scaling decisions in real-time:

```bash
# Monitor with defaults (45-second refresh interval)
./simple-demo-scaling-monitor.sh

# Custom SQLInstance name
./simple-demo-scaling-monitor.sh my-database

# Custom refresh interval (30 seconds)
./simple-demo-scaling-monitor.sh my-database default 30
```

**What it displays**:
- CPU utilization, free memory, and database connections
- Current instance class
- The `intelligent-scaling/reasoning` annotation, plus
  `status.observedInstanceClass` versus `spec.parameters.instanceClass`, which is
  how you see a change still in flight
- Refreshes continuously until stopped (Ctrl+C)

#### Expected Behavior
1. **CPU Spike**: Database CPU reaches 60%+ utilization (threshold for demo scaling)
2. **Metrics Collection**: function-rds-metrics captures CloudWatch data in XR status
3. **Trigger**: the status change fires the WatchOperation - no waiting for a
   schedule
4. **AI Analysis**: the self-hosted Qwen3-8B evaluates metrics against thresholds
5. **Scaling Decision**: instance class upgraded one step
6. **Convergence**: while `observedInstanceClass` lags
   `spec.parameters.instanceClass`, further decisions are suppressed - no
   wall-clock cooldown needed
7. **Performance Recovery**: CPU drops once the change completes

## Testing

```bash
up test run tests/test-sqlinstance/            # composition tests
up test run tests/e2etest-sqlinstance/ --e2e   # cloud e2e (no AI path)
```

> **Note:** `up test run tests/test-sqlinstance/` currently fails on `main`, and
> did so before the self-hosted-model work. Both cases diff on generated
> `metadata.name` and `ownerReferences[].uid` values that the fixtures still
> expect to be empty — stale expectations, not a composition fault. Worth
> fixing, because it is otherwise the natural regression gate and CI runs it on
> every PR.
>
> Note also that `tests/e2etest-sqlinstance/` exercises no model at all — the
> AI path lives in an Operation, not the composition — and it pins Crossplane
> `2.1.1-up.1`, below the `v2.3.0` Modelplane needs.

To test the scaling path itself, see **[End-to-end testing](#end-to-end-testing)**
below — four tiers, the first three free. For throughput, decision quality and
fleet-scale behaviour, see [`tests/scale/`](/tests/scale/).

## End-to-end testing

Five tiers, each adding exactly one variable. Everything below Tier 4 costs
nothing and needs no cloud account and no GPU. Work upward — a failure at a
lower tier is much cheaper to diagnose.

**Two instruments, not one.** The mock and a real model catch different
failures, and neither substitutes for the other:

| | Mock engine | Real model |
|---|---|---|
| Contract failures on demand (fences, prose, empty) | forced | cannot force |
| **Loop stability** | the only way to prove it | impossible — a real model occasionally emits something |
| Deterministic, safe in CI | yes | no |
| Format drift, prompt comprehension | no | yes |
| Gate reasoning over real text | no | yes |

So the mock gates every PR, and a real model gates acceptance. Use
`tests/e2e-local/eval-model.sh` to decide *which* real model is good enough
before committing to one — it replays the prompt extracted from the live
operation against the gate cases in `tests/scale/cases.json` and reports how
often the reply is actually usable.

Because `function-openai` reads its endpoint from the `gpt` Secret, it cannot
tell what is behind that URL. That single indirection is what makes the cheap
tiers possible: the entire control-plane path can be exercised against a pod.

| Tier | Adds | Cost | Time |
|---|---|---|---|
| 0 | nothing — renders locally | $0 | seconds |
| 1 | kind + a scripted mock engine | $0 | ~10 min |
| 2 | a real small model on CPU | $0 | ~20 min |
| 3 | Modelplane's routing layer (needs ~6 GiB free) | $0 | ~30 min |
| 3.5 | **Modelplane deploying the models** — fleet scheduler, DRA, canary (two clusters, ~16 GiB) | $0 | ~40 min |
| 4 | real GPU, real RDS | ~$860/mo + RDS | ~1 h |

### Tier 0 — no cluster

Verifies the composition and, importantly, that the convergence-gate fields the
scaling prompt depends on are actually populated.

```bash
up project build

up composition render --xrd=apis/definition.yaml \
  apis/composition-rds-metrics.yaml \
  examples/mariadb-xr-rds-metrics.yaml \
  --function-credentials=tests/test-credentials.yaml \
  --observed-resources=tests/fixtures/observed-rds-instance.yaml
```

Expect `status.observedInstanceClass: db.t3.micro` and
`status.observedInstanceStatus: modifying` on the rendered XR. The
`--observed-resources` path must be relative to the project root; an absolute
path is rejected.

### Tier 1 — kind + a scripted mock engine

This is the tier that catches regressions. The failures most likely to bite are
**contract** failures rather than reasoning failures, and only a mock can force
each one on demand.

Loop stability in particular *cannot* be tested with a real model: a real model
occasionally emits something, so you can never prove the no-op path is silent.

```bash
# Creates a KIND cluster, installs UXP, and deploys the project including
# operations/. The helm values clear Crossplane's default activations, which
# Modelplane's ManagedResourceActivationPolicy needs - harmless at Tier 1, and
# it saves recreating the cluster when you reach Tier 3.
up project run --local \
  --control-plane-name rds-ai-e2e \
  --helm-values tests/e2e-local/crossplane-values.yaml

# The stand-in model
kubectl apply -f tests/e2e-local/mock-engine.yaml
kubectl -n mock-model rollout status deploy/mock-engine

# Point the function at it. No Modelplane involved. This verifies the endpoint
# answers before writing the Secret, because a missing OPENAI_BASE_URL falls
# back to api.openai.com rather than failing.
tests/e2e-local/set-model-endpoint.sh mock

# A database to decide about. Observe-only, so nothing is created in AWS.
tests/scale/synthetic-fleet.sh 1 --seed-metrics
```

> **Check your kubecontext before applying anything.** `up project run --local`
> creates the cluster but may leave your current context pointing elsewhere -
> at a real control plane, if that is what you had selected. Confirm with
> `kubectl config current-context`, or work against an isolated kubeconfig:
> ```bash
> kind get kubeconfig --name rds-ai-e2e > /tmp/kc-rds-ai && export KUBECONFIG=/tmp/kc-rds-ai
> ```

`MOCK_MODE` on the Deployment selects the behaviour to test:

| `MOCK_MODE` | Reply | Must happen |
|---|---|---|
| `decide` | patch when CPU > 80, else empty | `instanceClass` patched, reasoning annotation set |
| `empty` | always empty | **no write, Operation count plateaus** |
| `fenced` | patch in ```` ```json ```` fences | *currently discarded silently* — see below |
| `garbage` | prose | *currently discarded silently* |

```bash
kubectl -n mock-model set env deploy/mock-engine MOCK_MODE=empty
kubectl -n mock-model rollout status deploy/mock-engine
```

**The four checks:**

```bash
# 1. Exactly one Operation per change, and the patch landed
kubectl get operation --sort-by=.metadata.creationTimestamp | tail -5
kubectl get sqlinstance -n database-team -o custom-columns=\
NAME:.metadata.name,WANT:.spec.parameters.instanceClass,GOT:.status.observedInstanceClass

# 2. Loop stability, with MOCK_MODE=empty.
#    Do NOT count Operation objects - successfulHistoryLimit (3) garbage-
#    collects them, so the count pins at 3 whether the loop has settled or is
#    spinning. Watch lastScheduleTime: on an idle fleet it must STOP advancing.
for i in $(seq 1 10); do
  kubectl get watchoperation rds-intelligent-scaling \
    -o jsonpath='{.status.lastScheduleTime}{"\n"}'
  sleep 60
done

# 3. What the function actually concluded
kubectl get operation -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="FunctionSuccess")].reason}{"\n"}{end}'

# 4. What the model was asked and answered
kubectl -n mock-model logs deploy/mock-engine
```

> **`fenced` and `garbage` are the important cases, and they will look like
> success.** `function-openai`'s `resourceFrom` does not strip markdown fences
> on the operation path — only its composition path does — and a parse failure
> is logged at debug while still reporting `FunctionSuccess=True` with no
> desired resources. So a model that has drifted into fenced output is
> indistinguishable from a fleet where nothing needs scaling. Verify with the
> `WANT` vs `GOT` columns above and the mock's own logs, not with a quiet
> Operation log. Porting the fence-stripping and an explicit failure condition
> into that path is the highest-value follow-up in this repo.

### Tier 2 — a real small model on CPU

Tier 1 proves the wiring; this finds out whether the *prompt* survives a real
model. Expect it to surface prompt bugs — fenced JSON, preambles, miscopied
resource names, misread gates.

```bash
kubectl apply -f tests/e2e-local/cpu-model.yaml
kubectl -n cpu-model rollout status deploy/llamacpp --timeout=15m  # downloads weights

kubectl -n crossplane-system delete secret gpt
kubectl -n crossplane-system create secret generic gpt \
  --from-literal=OPENAI_API_KEY=not-used \
  --from-literal=OPENAI_BASE_URL=http://llamacpp.cpu-model.svc.cluster.local:8000/v1 \
  --from-literal=OPENAI_MODEL=qwen
```

Then measure format reliability rather than eyeballing it:

```bash
tests/scale/bench-modelservice.sh 1 20   # set MODELSERVICE_* or edit ADDRESS lookup
```

The model is swappable in `cpu-model.yaml` and the choice is a real trade:
smaller is faster on CPU but much worse at emitting exact JSON. Anything under
about 1B will likely fail the format contract too often to be useful.

### Tier 3 — Modelplane's routing layer, still no GPU

Adds `ModelEndpoint` → `ModelService` in front of the CPU model.
`ModelEndpoint.spec.url` is parsed with plain `urllib.parse` and emits an
EndpointSlice with `addressType: FQDN` for any non-IP host, so a cluster-local
Service works — it is not restricted to external providers.

Independent of Tier 2 — this routes to the **mock** engine, not the CPU model.
What it tests is Modelplane's routing (`ModelEndpoint` → `ModelService` →
HTTPRoute, and the `status.address` plumbing), and the mock serves the same
OpenAI routes for ~15 MiB where the CPU model wants ~4 GiB. Modelplane's own
serving stack is several GiB, so keeping the engine cheap is what makes this
tier comfortably runnable.

Needs a control plane created with
`--helm-values tests/e2e-local/crossplane-values.yaml` — Modelplane's
`ManagedResourceActivationPolicy` requires Crossplane's default activations
cleared, and recreating the cluster is the only way to change that after the
fact.

> **Budget memory before starting, and check Docker's allocation rather than the
> machine's RAM.** Docker Desktop defaults to roughly half of physical memory,
> and `docker stats` reports that allocation — so a 32 GB machine presents as
> 16 GiB and will OOM around 10 GiB used. This cost me two failed runs and a
> wrong conclusion that the whole approach did not fit.
> ```bash
> sysctl -n hw.memsize | awk '{printf "physical: %.0f GB\n", $1/1e9}'
> docker info --format '{{.MemTotal}}' | awk '{printf "docker:   %.1f GiB\n", $1/1024/1024/1024}'
> docker stats --no-stream --format '{{.MemUsage}}\t{{.Name}}' | sort -hr | head
> ```
> Modelplane installs cert-manager, Envoy Gateway, Gateway API CRDs,
> kube-prometheus-stack, Node Feature Discovery and LeaderWorkerSet onto each
> inference cluster, several GiB in total. A bare control plane with this
> configuration sits around 3.4 GiB.

```bash
# RBAC and namespace. kubectl, not --init-resources: the file opens with a
# comment-only YAML document that crossplane project run rejects.
kubectl apply -f platform/00-prerequisites.yaml

# Declare the trim for Modelplane's ~14 unused cloud providers.
kubectl apply -f tests/e2e-local/lean-providers.yaml

kubectl apply -f platform/10-configuration.yaml
kubectl wait --for=condition=Healthy \
  configuration.pkg.crossplane.io/modelplane --timeout=15m

# ImageConfig binds only at ProviderRevision creation, so if provider-helm
# installed before the prerequisites it came up without their RBAC.
kubectl patch provider.pkg.crossplane.io upbound-provider-helm --type merge \
  -p '{"spec":{"runtimeConfigRef":{"name":"provider-helm-modelplane"}}}'

# NOW actually scale the unused providers down. The ImageConfig above is not
# enough under `up project run`: UXP sets an explicit runtimeConfigRef on every
# provider, which beats an ImageConfig-supplied runtime. Verified both
# orderings - all ten stayed at 1/1 either way.
tests/e2e-local/apply-lean-providers.sh

# The gateway, with a MetalLB pool derived from the real kind subnet.
# platform/20-inference-gateway.yaml is the cloud variant and has no
# loadBalancer block, which does not work on kind.
tests/e2e-local/apply-inference-gateway.sh
kubectl get inferencegateway default -w   # ctrl-C once it reports an address

# Route to the CPU model. No InferenceCluster, no InferenceClass, no DRA.
kubectl apply -f tests/e2e-local/modelplane-routing.yaml

tests/e2e-local/set-model-endpoint.sh modelservice ml-team qwen3-8b
```

This covers Modelplane's routing and `status.address` plumbing. It still does
**not** cover the fleet scheduler, DRA claims, or GPU provisioning.

### Tier 3.5 — Modelplane deploying the models, still no GPU

**This is the Modelplane showcase.** Tier 3 borrows only the routing layer and
points it at a pod someone else deployed. Here Modelplane *deploys* the models:
the fleet scheduler places them, DRA claims bind, the serving stack installs,
and two models sit behind one weighted endpoint.

Everything lives in [`platform/cpu-fleet/`](/platform/cpu-fleet/) — read that
README first, it explains why a GPU-less node can still satisfy the scheduler's
claimable-device requirement (a fake DRA driver) and why **two clusters are
mandatory**.

What this covers that Tier 3 does not:

- the fleet scheduler actually placing a deployment (`Scheduled 1 of 1`)
- `ResourceClaim`s binding to devices
- `ModelReplica` → `ModelEndpoint` → `ModelService` composed end to end
- a health-gated, weighted canary (90/10) across two different models
- a cross-cluster serving stack installed by Modelplane

```bash
# Control plane, per Tier 3 above: prerequisites, lean providers,
# platform/10-configuration.yaml, the provider-helm patch, the gateway.

# A SECOND cluster for the models. 1.34+ for the GA DRA APIs.
kind create cluster --name rds-ai-workload --image kindest/node:v1.34.0

# DRA driver, MetalLB, node labels, and the kubeconfig Secret on the control
# plane. Uses explicit --context throughout, because getting it wrong is silent.
platform/cpu-fleet/setup.sh rds-ai-workload rds-ai-e2e cpu-synthetic

kubectl apply -f platform/cpu-fleet/10-inference-class.yaml
kubectl apply -f platform/cpu-fleet/20-inference-cluster.yaml
kubectl get inferencecluster cpu-local -w    # serving stack, several minutes

kubectl apply -f platform/cpu-fleet/30-model-incumbent.yaml
kubectl apply -f platform/cpu-fleet/40-model-challenger.yaml
kubectl get modeldeployment,modelreplica -n ml-team -w

kubectl apply -f platform/cpu-fleet/50-model-service-canary.yaml
tests/e2e-local/set-model-endpoint.sh modelservice ml-team rds-scaler
```

Install Modelplane on a **fresh** control plane. v0.4.0 cannot be reached by
upgrading a v0.3.1 install in place — all fourteen XRDs change `spec.names`,
which is immutable. See
[`platform/cpu-fleet/README.md`](/platform/cpu-fleet/README.md).

### Tier 4 — the real thing

Apply `platform/` as written and use real `SQLInstance`s. See
[Prerequisites](#prerequisites). Only at this tier do the measurements in
[`tests/scale/`](/tests/scale/) become meaningful, and only here can
[`COST.md`](/COST.md)'s throughput estimates be replaced with measurements.

Three things are needed before a real `SQLInstance` can reconcile, and the
third fails silently:

```bash
# 1. AWS credentials, for both the provider and function-rds-metrics.
kubectl -n crossplane-system create secret generic aws-creds \
  --from-file=credentials="$HOME/.aws/credentials"
kubectl apply -f examples/clusterproviderconfig-aws-static.yaml

# 2. ACTIVATE THE AWS MANAGED RESOURCES. Required on any control plane hosting
#    Modelplane. Crossplane there runs with defaultActivations=[], which is
#    global, so nothing is active except what an activation policy names - and
#    Modelplane's own policy names only Helm and Kubernetes resources.
kubectl apply -f platform/05-aws-activation.yaml

#    Verify, because the failure mode is silence rather than an error:
kubectl api-resources --api-group rds.aws.m.upbound.io   # must list instances

# 3. A network for networkRef.id to select.
kubectl apply -f examples/ns-database-team.yaml
kubectl apply -f examples/network-rds-metrics.yaml
```

Confirm the credentials actually reach AWS before provisioning anything. An
observe-only resource forces a real API call and creates nothing - "external
resource does not exist" is the *success* case here, since it means the call
was made and authenticated:

```bash
kubectl get instance.rds.aws.m.upbound.io -A \
  -o custom-columns=NAME:.metadata.name,SYNCED:.status.conditions[?\(@.type==\"Synced\"\)].message
```

Note that SSO credentials are temporary. A run longer than their lifetime will
start failing mid-way with auth errors that look like provider bugs.

```bash
# Stress a real database and watch it react
# (see Performance Testing below for the scripts)
kubectl get operation --watch
```

Tear down with foreground cascading deletion, or the serving stack fails to
uninstall before the API server disappears:

```bash
kubectl delete inferencecluster eks-us-west --cascade=foreground
```

### Gotchas that will cost you an afternoon

Most of these come from Modelplane's own e2e harness, which is worth reading
(`e2e/run.sh` in the Modelplane repo) if you go past Tier 3.

1. **Crossplane must be ≥ v2.3.0**, installed with
   `--set-json 'provider.defaultActivations=[]'`. Note that
   `tests/e2etest-sqlinstance/main.k` pins `crossplane.version: "2.1.1-up.1"`,
   so **that existing E2ETest cannot host Modelplane** as written.
2. **A workload cluster serving models needs k8s v1.34+** for the DRA APIs. An
   older one fails confusingly much later.
3. **`platform/00-prerequisites.yaml` opens with a comment-only YAML document**,
   which `crossplane project run --init-resources` rejects and `kubectl`
   accepts. Apply it with kubectl.
4. **`ImageConfig` binds only at ProviderRevision creation.** If provider-helm
   installs before the prerequisites, it comes up without the RBAC they grant.
   Patch it afterwards:
   ```bash
   kubectl patch provider.pkg.crossplane.io upbound-provider-helm --type merge \
     -p '{"spec":{"runtimeConfigRef":{"name":"provider-helm-modelplane"}}}'
   ```
5. **On kind, MetalLB address pools must sit inside the *actual* kind subnet.**
   Usually `172.18.0.0/16`, but kind bumps to `.19`/`.20` when earlier Docker
   networks already hold it. A hardcoded pool leaves the LB IP off-subnet and
   requests simply time out.

   Detect it — and note the network usually has an IPv6 config *first*, so
   indexing config 0 gives you the wrong family:
   ```bash
   docker network inspect kind -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' \
     | grep -v ':' | head -1
   ```
   Derive the pool from that prefix, e.g. `172.19.0.0/16` →
   `172.19.255.200-172.19.255.250`.
6. **Check the `gpt` Secret first when anything looks wrong.**
   `OPENAI_BASE_URL` defaults to `api.openai.com` and `OPENAI_MODEL` to
   `gpt-4`, so a missing or misspelled key sends these decisions to OpenAI
   rather than failing.
7. **`up project build` rewrites `upbound.yaml` and strips comments.** Version
   values survive; explanatory notes do not.
8. **Modelplane's Configuration pulls every cloud provider** - GCP, Azure,
   Nebius, Vultr, AWS EKS/IAM/EFA - because they exist to *provision* clusters.
   None are needed when the model runs as a Deployment on the cluster you
   already have, and together they cost a couple of GiB.

   An ImageConfig alone will **not** scale them down under `up project run`.
   UXP sets an explicit `runtimeConfigRef: {name: default}` on every provider it
   installs, and an explicit ref on the Provider beats a runtime supplied by an
   ImageConfig. Modelplane's own trim works because its e2e uses plain
   `crossplane project run`, which does not inject that ref. Verified applying
   the ImageConfig both before and after the Configuration - all ten target
   providers stayed at `ready=1/1` either way.

   `tests/e2e-local/apply-lean-providers.sh` patches each provider directly,
   which does work. Modelplane's Configuration stays `Healthy=True` with them at
   zero - package health does not depend on pod readiness.
9. **Modelplane pins its AWS providers to v2.6.0 - v0.3.1 and v0.4.0 alike -
   and a floating constraint here will break it.** `provider-aws-rds: v2`
   resolves to v2.7.2, which pulls `provider-family-aws@v2.7.2`. Modelplane's
   `provider-aws-eks` (pinned v2.6.0) then fails with *"incompatible dependencies: existing
   package provider-family-aws@v2.7.2 is incompatible with constraint v2.6.0"*
   and its Configuration never goes Healthy.

   `upbound.yaml` pins `provider-aws-rds` to **v2.6.0** for this reason. But
   note that `configuration-aws-network` also pulls `provider-aws-ec2`, which
   resolves to v2.7.2 on its own, so **three** packages have to agree. On a
   cluster that already installed the wrong versions, Crossplane will not
   downgrade the family provider by itself — patch all three:

   ```bash
   for p in aws-rds aws-ec2 family-aws; do
     kubectl patch provider.pkg.crossplane.io "upbound-provider-$p" --type merge \
       -p "{\"spec\":{\"package\":\"xpkg.upbound.io/upbound/provider-$p:v2.6.0\"}}"
   done
   ```

   **Pin before the first install.** Downgrading in place does not reliably
   work: the v2.7.2 ProviderRevisions stay Active because the v2.6.0 ones
   cannot activate while the old family revision is still active, and the old
   one is not replaced because nothing healthy supersedes it. Patching the three
   packages leaves both sets of revisions half-migrated. Recreating the control
   plane with the pins already in `upbound.yaml` is faster than untangling it.

   Re-check this whenever either side bumps. It is the first thing to suspect if
   Modelplane's Configuration sits at `Healthy=False` with everything else
   looking fine.
10. **Do not use Modelplane's own `e2e/lean-control-plane.yaml` here.** It
   matches the prefix `provider-aws-`, which also catches `provider-aws-rds`
   and `provider-aws-ec2` - the two providers this configuration needs. An
   ImageConfig runtime overrides even an explicit `runtimeConfigRef`, so it
   would silently scale the RDS provider to zero and the scaling demo would
   stop working with no obvious cause. Ours names the AWS families
   individually.
11. **`kubectl wait --for=condition=Ready` on an `InferenceGateway` returns
   before `status.address` is written.** Reading the address on the next line
   therefore yields an empty string. Measured on a clean install: `Ready=True`
   with no address, populated a few seconds later. The same applies to
   `ModelService.status.address`. `kubectl get inferencegateway default -w` and
   waiting for the address to appear is the safe interactive form; in a script,
   poll the field itself rather than the condition:

   ```bash
   until [[ -n "$(kubectl get inferencegateway default \
     -o jsonpath='{.status.address}')" ]]; do sleep 5; done
   ```

## Crossplane v2.0 Operations

This configuration includes **Crossplane Operations** for automated intelligent scaling using both scheduled and reactive patterns. Operations are automatically deployed with `up project run`.

### WatchOperation: reactive scaling analysis

- **Trigger**: any change to a `SQLInstance` labelled `scale: me`, in any
  namespace. Crossplane creates one Operation per changed resource and injects
  that resource into every pipeline step itself.
- **Model**: whatever the `gpt` Secret's `OPENAI_BASE_URL` points at - by
  default the self-hosted Qwen3-8B.
- **Concurrency**: `Forbid`, not the `Allow` default.
- **Convergence**: `status.observedInstanceClass` vs
  `spec.parameters.instanceClass`, not a wall-clock cooldown.
- **Thresholds**: up on CPU >80%, connections >80%, free memory <15%; down only
  when all three are comfortably clear.
- **Progression**: `db.t3.micro → db.t3.small → db.t3.medium → db.t3.large`
- **Audit trail**: a reasoning annotation on real scaling events, plus the
  retained Operation objects.

Two things worth knowing before editing it:

**Do not add `requirements.requiredResources`.** Crossplane appends the
watched-resource selector to every step, and `function-openai` fails hard when
that requirement resolves to anything other than exactly one resource
(`too many resources sent to the function. expected 1`). This is
also why the old `CronOperation` could not serve more than one database: it
selected by label, so a second matching `SQLInstance` broke it outright.

**Do not make no-ops write anything.** Any write re-triggers the watch.

### Quick Start with Operations
1. **Set up the `gpt` credential** (see Prerequisites - it carries the endpoint
   and model, not just the token):
   ```bash
   kubectl -n crossplane-system create secret generic gpt \
     --from-literal=OPENAI_API_KEY=not-used-by-vllm \
     --from-literal=OPENAI_BASE_URL="$(kubectl get ms qwen3-8b -n ml-team \
        -o jsonpath='{.status.address}')/v1" \
     --from-literal=OPENAI_MODEL=qwen
   ```

2. **Deploy Configuration and Operations**:
   ```bash
   up project run  # Automatically includes operations/
   ```

3. **Deploy Example with Scaling Labels**:
   ```bash
   # Network dependency
   kubectl apply -f examples/network-rds-metrics.yaml
   
   # Database with scaling enabled
   kubectl apply -f examples/mariadb-xr-rds-metrics.yaml
   ```

4. **Monitor Operations**:
   ```bash
   # The WatchOperation and the Operations it creates (all cluster-scoped)
   kubectl get watchoperation,operation

   # Loop stability: lastScheduleTime must STOP advancing on an idle fleet.
   # Counting Operation objects does not work - successfulHistoryLimit GCs
   # them, so the count pins at its limit either way.
   kubectl get watchoperation rds-intelligent-scaling \
     -o jsonpath='{.status.lastScheduleTime}{"\n"}'

   # A model drifting off-format now shows up rather than looking like a no-op
   kubectl get operation -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="FunctionSuccess")].reason}{"\n"}{end}' | sort | uniq -c
   ```

### Example Resources for Operations Testing
The configuration includes dedicated examples for operations testing:
- `examples/network-rds-metrics.yaml`: Network setup for RDS metrics testing
- `examples/mariadb-xr-rds-metrics.yaml`: MariaDB SQLInstance with `scale: me` label for operation targeting
- `examples/postgres-xr-rds-metrics.yaml`: PostgreSQL SQLInstance for testing

## Deployment

- Execute `up project run` (automatically includes operations)
- Alternatively, install the Configuration from the [Upbound Marketplace](https://marketplace.upbound.io/configurations/upbound/configuration-aws-database)
- Check [examples](/examples/) for example XR(Composite Resource)

## Next steps

This repository serves as a foundational step. To enhance the configuration, consider:

1. create new API definitions in this same repo
2. editing the existing API definition to your needs

To learn more about how to build APIs for your managed control planes in Upbound, read the guide on [Upbound's docs](https://docs.upbound.io/).