# Real-AWS run: the pipeline works, and it over-scaled a real database

Despite living under `e2e-local/`, this records a run against **real AWS** -
real VPC, real RDS, real CloudWatch - with inference served by the local CPU
fleet (Modelplane v0.4.0, Qwen2.5-1.5B incumbent). No GPU.

It is the first time the product, rather than the platform, was tested against
data nobody synthesised.

## What worked

Everything mechanical, first time:

| Step | Evidence |
|---|---|
| Credentials reach AWS | STS identity resolved; an observe-only `Instance` returned "external resource does not exist", i.e. the call was made and authenticated |
| Network provisioning | 16/16 managed resources Ready - VPC, 4 subnets, security groups, IGW, route tables |
| RDS provisioning | MariaDB 10.11 `db.t3.micro`, available in ~6 min |
| Convergence gates from real AWS | `observedInstanceClass: db.t3.micro`, `observedInstanceStatus: available` |
| Real CloudWatch metrics | CPU 29.67%, 0 connections, 205 MiB freeable, ReadIOPS 7.1, WriteIOPS 80.0 |
| WatchOperation -> model -> patch | Operations completed, patches applied, AWS resized |
| Identity guard | every decision named the correct resource; no mismatches |

## What went wrong: it scaled up a database that needed nothing

The model emitted `db.t3.small`. Crossplane applied it. **AWS really resized
the instance**, and `atProvider.instanceClass` confirms `db.t3.small`,
`status: available`.

The prompt's up-conditions are "any of: CPUUtilization > 80,
DatabaseConnections > 80% of the class limit, FreeableMemory under 15% of class
memory". At decision time:

```
FreeableMemory     : 215220224 bytes (205 MiB)
db.t3.micro memory : 1073741824 bytes (1 GiB)
free as % of class : 20.0%
up-threshold       : < 15%   -> NOT MET

CPUUtilization     : 29.67%  vs > 80   -> NOT MET
DatabaseConnections: 0       vs > 80%  -> NOT MET
```

No up-condition was met. The correct output was a no-op restating
`db.t3.micro`. It was also **unstable**: of four decisions on the same
resource, two said `db.t3.small` and two said `db.t3.micro`.

It also broke its own output contract. The prompt requires a scaling action to
carry an `intelligent-scaling/reasoning` annotation. The emitted patches had
none, so the audit trail the README advertises is empty for the one event that
needed it.

## Why the offline eval did not catch this

The eval scored this model 79% correct and **0% over-scaled**. That result was
real but measured on synthetic cases, and two differences matter:

1. **The memory rule requires knowledge the prompt does not supply.** "Under
   15% of class memory" needs the class-to-memory mapping - that `db.t3.micro`
   is 1 GiB. Nothing in the prompt says so, so the model must recall AWS
   instance specs and then divide. 205 MiB *reads* low in absolute terms, and
   the model appears to have judged it that way. The eval's cases used
   `FreeableMemory: 800000000` - about 75% of a micro - comfortably clear of
   the boundary, so they never probed this.
2. **A real XR is bigger.** ~3,200 prompt tokens against the synthetic
   ~2,710, because real `status` carries six CloudWatch metrics plus
   `atProvider`. More context to lose the relevant numbers in.

The lesson is not "the eval was wrong" but "the eval's inputs were too kind".
Cases should be generated from a real XR, and should include values *near* each
threshold rather than comfortably inside it.

## The fixes this run argues for

1. **Put the class-to-memory table in the prompt**, or better, have the
   composition compute `freeableMemoryPercent` and `connectionsPercent` in
   `status.performanceMetrics` so the model compares two numbers instead of
   recalling hardware specs and dividing. A model that cannot be trusted to
   know a micro is 1 GiB should not be asked to.
2. **Gate the patch on a deterministic threshold check.** The model is useful
   for judgement; it should not be the only thing standing between a metric and
   a billable resize. If no up-condition is met, a scale-up should be refused
   the same way a foreign resource identity is - in code.
3. **Enforce the reasoning annotation.** A scale-up without one should be
   rejected, since it is both a contract violation and the loss of the audit
   trail.
4. **Add near-threshold cases to `tests/scale/cases.json`**, derived from a
   real XR.

## Engine sizing, and a concurrency finding

The first three Operations wedged in `PipelineRunning` for 8+ minutes and
produced nothing. Cause was engine capacity, not the model:
`n_slots = 4, n_ctx_slot = 8192, kv_unified = true` means one 8,192-token KV
cache shared across four slots, and three concurrent ~3,200-token prompts need
~9,600. Raising `--ctx-size` to 16384 on both ModelDeployments fixed it - the
same Operations then completed.

**`concurrencyPolicy: Forbid` does not prevent concurrent Operations for the
same watched resource.** All three of those Operations targeted the identical
SQLInstance. Three status writes during startup - RDS going available, metrics
landing, gates populating - each spawned an Operation and they ran in parallel.
Whatever `Forbid` governs, it is not this, and the docs claiming it bounds
concurrency were wrong. At fleet scale this is the difference between 100
databases producing 100 sequential decisions and 100 simultaneous ones against
one engine.

## Operational notes

- **The fake DRA driver is fragile across restarts, twice over.** Stopping and
  starting the clusters regenerates the driver's device UUIDs, so existing
  ResourceClaims reference CDI devices that no longer exist and engines wedge in
  `CreateContainerError`. Separately, the driver pod's IP changes and kubelet
  keeps the stale plugin endpoint - pods then sit in `ContainerCreating` for an
  hour with only a `Scheduled` event and nothing in the pod's own events; the
  error is in the kubelet journal (`dial tcp <old-ip>:1063: operation was
  canceled`). Restart the DaemonSet, then delete the stuck pods.
- **ModelDeployments report `Ready=True` while their engines are down.** Do not
  trust that condition alone; check the engine pods.
- SSO credentials are temporary. This run outlived none of them, but a longer
  one would.
