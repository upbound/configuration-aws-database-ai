# CPU fleet end-to-end run (Modelplane v0.4.0, fixed function-openai)

Full teardown and rebuild of both kind clusters onto Modelplane **v0.4.0**, zero
GPUs, 27 minutes wall clock. Supersedes
[`cpu-fleet-e2e-run.md`](cpu-fleet-e2e-run.md), which ran v0.3.1 with the
unfixed published `function-openai` and is kept for the failure it reproduced.

## Why a rebuild rather than an upgrade

v0.4.0 cannot be reached by upgrading a v0.3.1 install. All fourteen Modelplane
XRDs add a category to `spec.names`, which is immutable on a
CompositeResourceDefinition, so the new revision goes Active and stays
`Healthy=False` with `reason: UnhealthyPackageRevision`:

```
cannot establish control of object: CompositeResourceDefinition
"aksclusters.infrastructure.modelplane.ai" is invalid:
spec.names: Invalid value: "object": Value is immutable
```

Two things about this cost real time and are worth stating plainly:

- **The stalled revision is inert, not destructive.** Throughout it the v0.3.1
  fleet kept serving - both ModelDeployments Ready, canary endpoint HTTP 200.
  Nothing looks broken, which is exactly why waiting it out is tempting. It does
  not clear on retry.
- **`Healthy=True` on an *Inactive* revision means nothing.** An Inactive
  revision reports healthy because it is not establishing control of anything.
  Reverting the pin and seeing the v0.4.0 revision go `Inactive healthy=True` is
  not recovery. Check the *Active* revision.

Downgrading is not an escape either - the embedded composition functions are
digest-pinned, so v0.3.1 cannot reinstall over v0.4.0
(`existing package modelplane_compose-inference-cluster@sha256:953b005... is
incompatible with constraint sha256:a880d9fc...`). Once a control plane has seen
v0.4.0, the way out is forward or fresh.

**A fresh install has none of this.** Verified here: 14/14 XRDs Established
first time, with their new categories.

| category added | XRDs | count |
|---|---|---|
| `infrastructure` | aks/eks/gke/nebius/vultr clusters, servingstacks | 6 |
| `platform` | inferenceclasses, inferenceclusters, inferencegateways | 3 |
| `models` | modelcaches, modeldeployments, modelendpoints, modelreplicas, modelservices | 5 |

## What Modelplane did, verified

| Capability | Evidence |
|---|---|
| Configuration health | `modelplane` `INSTALLED=True HEALTHY=True`, one Active revision, no Inactive predecessor |
| Fleet scheduling | `ReplicasScheduled=True (ReplicasCreated)` for both deployments |
| DRA ResourceClaim binding | claims `allocated,reserved` on `gpu-0` and `gpu-1`, driver `gpu.example.com`, 8 fake devices, GPU-less node |
| Cross-cluster serving stack | `InferenceCluster cpu-local` `SYNCED=True READY=True`; 10/10 Helm releases on the workload cluster |
| Health-gated endpoints | both `ModelEndpoint`s composed only after their `ModelReplica` went Ready |
| Weighted canary | control-plane HTTPRoute: `scaler-incumbent weight=9`, `scaler-challenger weight=1`; both engines observed taking traffic |
| Unified endpoint | `http://172.19.255.200/ml-team/rds-scaler` - HTTP 200 |
| Two-hop routing | control-plane Traefik `.200` -> per-replica Envoy `.100` on the workload cluster |
| `spec.stack` defaulting | v0.4.0's one new field defaults to `Standard`; `20-inference-cluster.yaml` leaves it unset and needs no change |

Nothing in `platform/cpu-fleet/` needed editing for v0.4.0. Diffing the two
packages' XRD schemas: `InferenceClass` and `ModelService` identical,
`ModelDeployment` description text only, `InferenceCluster` adds `spec.stack`.

`SYNCED/READY` also became coherent. On the v0.3.1 rig `InferenceCluster` and
`ServingStack` sat at `SYNCED=False READY=True`; here both reach `True/True`.
One data point on a clean install, so this is an observation, not an attribution
to v0.4.0.

## Timings

| Elapsed | Stage |
|---|---|
| +1m | teardown, workload cluster created, `up project run` collecting resources |
| +6m | control plane up, project + network Configuration Healthy, Modelplane applied |
| +13m | Modelplane Configuration Healthy, all 14 XRDs Established |
| +18m | gateway Ready at `172.19.255.200`, workload cluster registered |
| +22m | `InferenceCluster` Ready - serving stack installed |
| +27m | both models Ready, canary composed, endpoint answering |

## Decision quality

Measured through both routing paths. Numbers, raw output and the attribution
argument are in [`README.md`](README.md); the short version:

| Path | Correct | Over-scaled | Malformed |
|---|---|---|---|
| incumbent direct, via `ModelEndpoint` | **19/24 (79%)** | 0% | 0 |
| 90/10 canary, via `ModelService` | 18/24 (75%) | 0% | 1 |

The direct run reproduced the pre-existing 79% baseline *exactly* - same cases,
same verdicts, same single temperature-0 flip - so Modelplane's routing costs
nothing measurable in decision quality. The 4-point canary gap is one malformed
response out of 24, attributable to the 0.5B challenger by its failure mode
(`prose` instead of JSON), which is the split behaving as designed: a knowingly
bad model is in production traffic and its damage is bounded to a tenth of it.

## Honest limits of this run

- **No real database.** Decision quality was measured against the recorded gate
  cases in `tests/scale/cases.json` and against synthetic observe-only XRs with
  seeded metrics - not a live RDS instance reacting to real load. The
  WatchOperation path *was* exercised; see the section below.
- **`function-openai` was not in the measured path.** `eval-model.sh` builds
  requests itself, so these numbers measure model and prompt, not the function.
  The function's four fixes are verified separately in
  [`function-openai-fixed-comparison.md`](function-openai-fixed-comparison.md).
- **n=24 per path.** A 4-point difference is one case. The attribution rests on
  the failure mode being the challenger's signature, not on the margin.
- **No GPU path.** `platform/` (Qwen3-8B on an L4) remains unexercised.

## The end-to-end decision loop, and a wrong-resource bug

Everything above measures the platform. This section is the first time the
actual product was exercised on this rebuild: a `SQLInstance` changing, the
WatchOperation firing, `function-openai` calling the self-hosted model, and a
patch landing. `tests/scale/synthetic-fleet.sh 5 --seed-metrics`, observe-only,
no AWS spend.

**What worked.** Five XRs produced **eight** Operations - the create and the
status seeding each bump `resourceVersion`, and the Operation name hashes it, so
the documented "any write re-triggers" property is visible in the wild. The
model was reached through Modelplane's canary endpoint, and the prompt arrived
at ~985-2,710 tokens rather than the ~5,167 of the `html/template` bug, so that
fix holds through the real control plane and not just in unit tests. Four of the
five no-op cases were decided correctly. The loop settled rather than spinning.

**What did not.** Two distinct defects, and the first is serious.

### 1. Under concurrency the model patches the WRONG resource

Five of the eight Operations emitted a patch whose `metadata.name` and
`namespace` were copied verbatim from a **few-shot example in the prompt**
rather than from the watched resource:

```
Pipeline step "decide": {"apiVersion":"aws.platform.upbound.io/v1alpha1",
"kind":"SQLInstance","metadata":{"name":"db-d","namespace":"team-y",
"annotations":{"intelligent-scaling/reasoning":"CPU 93% sustained above 80%"}},
"spec":{"parameters":{"instanceClass":"db.t3.small"}}}

cannot apply desired resource: namespaces "team-y" not found
```

`db-d`/`team-y` is example 4 in `operations/rds-intelligent-scaling-watch/
operation.yaml`, reproduced byte-for-byte including its "CPU 93%" reasoning -
for databases at CPU 37 and 85. One Operation copied example 1 (`db-a`/`team-x`)
instead, so it is not one sticky line; it copies whichever.

**This only failed safe because `team-y` does not exist here.** Crossplane did
attempt the apply. On a real multi-tenant fleet where that namespace and name
exist, the patch would resize a different team's database. Nothing in the
current path prevents it: the model's output is server-side-applied as returned,
and no code checks that the returned identity matches the watched resource.

Concurrency is implicated, not model quality alone:

| Load | Wrong identity |
|---|---|
| 8 Operations at once | 5 of 8 |
| 1 Operation, sequential | 0 of 2 |

The mechanism is arithmetic. The engine starts with
`n_slots = 4, n_ctx_slot = 8192, kv_unified = 'true'` - one 8,192-token KV cache
shared across up to four concurrent requests - and a real watched `SQLInstance`
renders to about **2,710 tokens**, far more than the eval's synthetic cases.
Three concurrent requests need ~8,130 tokens and just fit; four need ~10,840 and
do not. The engine returns `500 Context size has been exceeded`, and under that
pressure the logs show KV manipulation (`n_past was set to 2662`). Eight
simultaneous Operations oversubscribe the cache roughly threefold.

Three fixes, and the third is the one that matters:

1. Size the engine for concurrency: `--ctx-size` >= `n_slots` x prompt size
   (4 x 2,710 -> 16384), or drop `--parallel` to 1-2. **Not done.**
2. Bound WatchOperation concurrency so the fleet cannot oversubscribe one
   engine. **Not done.**
3. **Validate the returned identity in code.** **Done** - see below. This is a
   safety invariant and must not depend on model quality, prompt wording, or
   engine capacity. The other two reduce how often the model misbehaves; only
   this one bounds the damage when it does.

### The identity guard, and how it was verified

Shipped in `xpkg.upbound.io/solutions/function-openai:v0.3.9-selfhosted-fixes-2`.
The operation path compares the returned resource's group, kind, namespace and
name against the watched resource and refuses a mismatch:
`FunctionSuccess=False`, reason `ResourceIdentityMismatch`, a warning event
naming both identities, no desired resources. API *version* is excluded - two
versions of one kind are the same object, so rejecting on version would refuse
correct output.

It refuses rather than rewriting the identity to match. A decision reasoned
about the wrong resource cannot be trusted to carry the right instance class.

**Verifying it needed a new instrument.** A real model cannot be made to
regurgitate on demand, and the concurrency that triggered it did not reproduce
on a second attempt (2 Operations fired rather than 8). Waiting for a flaky
failure to recur is not a test. So `tests/e2e-local/mock-engine.yaml` gained a
`foreign-resource` mode that returns example 4 verbatim - the exact production
reply - making the failure deterministic. This is the mock earning its keep in
the way [`../../README.md`](../../README.md) claims: forcing a contract failure
a real model cannot be asked for.

Both directions, on the live rig through the real control plane:

| Mock mode | Model returns | Result |
|---|---|---|
| `foreign-resource` | `team-y/db-d` | **refused.** Event names both identities. No `cannot apply desired resource` event - Crossplane never attempted it. Previously it did. |
| `decide`, CPU 95 | `database-team/guardtest-1` | **applied.** `db.t3.micro` -> `db.t3.small` |

The second row matters as much as the first: it rules out a guard that simply
blocks everything.

In unit tests, 18 subtests cover it, including a negative control - with the
guard stubbed out the three rejection cases fail (*"want NO desired resources,
got 1 - a patch for a foreign resource would reach the API server"*) while both
apply-cases still pass, so the tests are specific to the guard rather than
merely sensitive.

**Known gap.** A refused patch leaves the Operation reporting `Succeeded=True`,
because the function returns a condition rather than a fatal result. The damage
is prevented, but someone watching `kubectl get operation` sees green; the
signal is the warning event. Making it fatal would surface it and consume the
retry budget. Deliberate open choice, not an oversight - and the same is true of
the pre-existing `UnparseableModelOutput` path.

**Also found while debugging this:** when the watched resource has been deleted,
the required-resources list is empty and `function-openai` reports *"too many
resources sent to the function. expected 1"* - the `len(rs) != 1` check does not
distinguish zero from many. Harmless but actively misleading; it cost real time
here.

Worth noting the sample sizes: 8 concurrent versus 2 sequential. The effect is
large and the mechanism is confirmed independently, but the ratio is not
precisely measured.

### 2. It misses genuine scale-ups

`synthetic-scale-5` at **CPU 85** - clearly over the 80 threshold - was left at
`db.t3.micro`. That is not a new bug: it is the 21% missed rate the offline eval
measured, and `scale up: cpu 81 (just over)` is a missed case there too. The
model under-reacts near the threshold. The failure direction is safe (a slow
response, not a surprise bill), but "AI-scaled RDS" does not reliably scale up
at 85% CPU with this model, and that should be said plainly.

### What this means for the demo

The platform is solid and the plumbing is correct. The *decision layer* is not
production-ready: it needs the identity guard at minimum, and a deterministic
threshold check alongside the model would fix defect 2 outright. For a
demonstration of Modelplane - fleet scheduling, DRA, cross-cluster serving,
weighted canary - none of this detracts. For a claim that a 1.5B model can be
trusted to resize databases unsupervised, it does.
