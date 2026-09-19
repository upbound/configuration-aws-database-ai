# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an **AI-powered Crossplane configuration for AWS databases** that combines traditional infrastructure-as-code with intelligent, automated scaling capabilities. The project provides a foundational setup for deploying and managing RDS instances that can automatically scale based on CloudWatch metrics analyzed by Claude AI.

## Architecture

### Core Components
- **XRD (CompositeResourceDefinition)**: `apis/definition.yaml` defines the SQLInstance API (v2 namespaced) with support for PostgreSQL and MariaDB engines
- **Composition**:
  * RDS metrics composition: `apis/composition-rds-metrics.yaml` - CloudWatch metrics integration with AI scaling
- **Embedded Function**: `functions/sqlinstance/main.k` contains KCL logic for RDS SubnetGroup, Instance, and connection Secret creation
- **AI Pipeline**: the composition only fetches metrics. Inference happens in a
  `WatchOperation`, not in the composition pipeline, so a slow or unavailable
  model cannot block reconciliation.
- **Crossplane Operations**: `operations/` contains a `WatchOperation` that reacts
  to XR changes. It replaced a `CronOperation`, whose schedule existed only to
  rate-limit hosted-model API spend.
- **Self-hosted model**: `platform/` deploys a Modelplane inference cluster
  serving Qwen3-8B on one NVIDIA L4. `function-openai` reaches it via
  `OPENAI_BASE_URL` in the `gpt` Secret, calling vLLM's OpenAI-compatible
  `/v1/chat/completions`.
- **CPU fleet**: `platform/cpu-fleet/` is the same thing with no GPU - Modelplane
  deploys, schedules and canaries two CPU models behind one weighted
  `ModelService`, using a fake-DRA driver to satisfy the scheduler's claimable
  device requirement. This is the Modelplane showcase; see its README.

### Intelligent Scaling Pipeline
Event-driven, in two places rather than one pipeline:

**Composition** (on every reconcile)
1. `function-rds-metrics` writes CloudWatch data to `status.performanceMetrics`
2. The embedded KCL function surfaces `status.observedInstanceClass` and
   `status.observedInstanceStatus` from the composed RDS Instance

**WatchOperation** (on any XR change)
3. `function-openai`, pointed at the self-hosted model by the `gpt` Secret,
   either patches `spec.parameters.instanceClass` or writes nothing at all

Writing nothing on a no-op is load-bearing, not an optimisation: the generated
Operation's name hashes the watched resource's `resourceVersion`, so any write
re-triggers the analysis. A no-op that stamped a timestamp annotation would loop
forever - which is why the old prompt's annotation-age logic had to go, along
with asking a model that has no clock to compute elapsed time.

### Key Features
- **Multi-Engine Support**: PostgreSQL and MariaDB with configurable versions
- **Network Integration**: References external network configurations via `networkRef.id`
- **Intelligent Scaling**: AI-driven scaling decisions with full audit trails
- **Operations Integration**: Crossplane v2.0 Operations for scheduled and reactive scaling
- **Connection Secrets**: Manual Secret composition (v2 pattern) exposing connection details (endpoint, host, port, username, password)

## Development Commands

### Core Upbound DevEx Workflow
```bash
# Build and deploy the configuration
up project build && up project run

# Test composition rendering
up composition render --xrd=apis/definition.yaml apis/composition-rds-metrics.yaml examples/mariadb-xr-rds-metrics.yaml --function-credentials=tests/test-credentials.yaml

# Run composition tests
up test run tests/test-sqlinstance/
up test run tests/e2etest-sqlinstance/ --e2e
```

### AI Scaling System Setup
```bash
# The gpt Secret carries the endpoint and model as well as the token.
# OPENAI_API_KEY is required but unchecked by vLLM.
kubectl -n crossplane-system create secret generic gpt \
  --from-literal=OPENAI_API_KEY=not-used-by-vllm \
  --from-literal=OPENAI_BASE_URL="$(kubectl get ms qwen3-8b -n ml-team \
     -o jsonpath='{.status.address}')/v1" \
  --from-literal=OPENAI_MODEL=qwen

# Deploy with operations (includes the scaling WatchOperation)
up project run  # Automatically includes operations/ directory

# Monitor scaling operations
kubectl get watchoperation,operation --watch   # cluster-scoped, no -n
```

### Load Testing for Scaling Validation
```bash
# MySQL/MariaDB CPU stress test to trigger AI scaling
for i in {1..8}; do
    mysql \
      --host=your-rds-endpoint.region.rds.amazonaws.com \
      --user=masteruser \
      --password=your-password \
      --execute="SELECT BENCHMARK(1000000000, MD5('trigger_scaling_$i'));" &
done

# Monitor scaling decisions and instance changes
kubectl get sqlinstance your-db-name -n default -o jsonpath='{.metadata.annotations}' | jq .
kubectl get instance.rds.aws.m.upbound.io -n default -l crossplane.io/composite=your-db-name -o jsonpath='{.items[0].spec.forProvider.instanceClass}'
```

## Key Files and Architecture

### Function Implementation (`functions/sqlinstance/main.k`)
- Creates RDS SubnetGroup with network label selectors matching `networkRef.id`
- Creates RDS Instance with configurable engine, storage, authentication, and networking
- Handles both auto-generated passwords and secret references
- **v2 Pattern**: Manually composes Kubernetes Secret with connection details (endpoint, host, port, username, password)
- Uses typed `corev1.Secret` model from Kubernetes API dependency

### Composition
- **RDS Metrics**: Full pipeline with metrics collection, AI analysis via Claude, and auto-ready function
- Pipeline: `sqlinstance` → `fetch-metrics` (function-rds-metrics) → `crossplane-contrib-function-auto-ready`

### Test Coverage (`tests/`)
- **Composition Tests**: `test-sqlinstance/main.k` validates resource creation for MariaDB and PostgreSQL
- **E2E Tests**: `e2etest-sqlinstance/main.k` performs full cloud deployment testing
- **Test Structure**: Uses `CompositionTest` and `E2ETest` resources with function credentials support

### Operations Integration (`operations/`)
- **WatchOperation**: reacts to any change on a `SQLInstance` labelled `scale: me`, in any namespace
- **Convergence**: `status.observedInstanceClass` vs `spec.parameters.instanceClass` - no wall-clock cooldown
- **Concurrency**: `Forbid`, not the `Allow` default
- **Thresholds**: CPU >80%, free memory <15%, connections >80%
- **One resource per Operation**: `function-openai` fails hard on more than one watched resource ("too many resources sent to the function. expected 1"), and Crossplane injects the selector itself - never declare `requirements.requiredResources`
- **Instance Progression**: `db.t3.micro → db.t3.small → db.t3.medium → db.t3.large`

## Dependencies and Integration

### Required Dependencies (`upbound.yaml`)

**`up project build` rewrites `upbound.yaml` and strips comments from it.** Do
not put explanatory notes there - they will not survive a build. Version values
are preserved.

**Scaling inference uses `function-openai` (v0.3.9), not `function-claude`.** It
reads `OPENAI_BASE_URL`, `OPENAI_MODEL` and `OPENAI_API_KEY` from a Secret named
`gpt`. `OPENAI_BASE_URL` defaults to api.openai.com and `OPENAI_MODEL` to
`gpt-4`, so a missing key silently sends decisions to OpenAI - check the Secret
first when something looks wrong.

**Published releases up to and including v0.3.9 are unusable against a
self-hosted engine.** Five bugs, all fixed on the `fix-selfhosted-issues` branch
of `function-openai` and verified end to end (see
`tests/e2e-local/results/function-openai-fixed-comparison.md` and
`tests/e2e-local/results/cpu-fleet-e2e-run-v040.md`):

1. prompts built with `html/template`, so the interpolated resource arrives
   HTML-escaped - unparseable and ~4x larger (measured 5,167 vs 930 tokens)
2. no `max_tokens` sent, so the engine generates to context exhaustion and the
   Operation hangs indefinitely
3. markdown fences stripped only on the composition path, and only ` ```yaml `
4. unparseable output reported as `FunctionSuccess=True`, indistinguishable
   from a deliberate no-op
5. the model's output applied to whatever resource the model named, so a reply
   that copied a few-shot example patched a resource nobody asked about - the
   safety bug, detailed below

With published v0.3.9 a database at 37% CPU was scaled up; with the fixed build
the same input correctly does nothing.

`function-claude` was the original choice and is not used. For the record: no
published release of it carries a `baseURL` field, including v0.4.9.

- **provider-aws-rds**: v2 (namespaced) - RDS resource management
- **configuration-aws-network**: Network infrastructure (v2 namespaced)
- **k8s**: v1.33.0 - Kubernetes API for Secret model
- **function-auto-ready**: Composition readiness management
- **function-openai**: `xpkg.upbound.io/solutions/function-openai:v0.3.9-selfhosted-fixes-2` - scaling decisions against any OpenAI-compatible endpoint. Published upstream releases are unusable here; see above.
- **function-rds-metrics**: v0.0.7 - CloudWatch metrics collection

### API Parameters
- **Required**: `region`, `engine`, `engineVersion`, `storageGB`, `networkRef.id`, `passwordSecretRef`
- **Optional**: `instanceClass` (default: db.t3.micro), `autoGeneratePassword`, `publiclyAccessible`, `managementPolicies`
- **v2 Changes**: `managementPolicies` replaces `deletionPolicy`, supports: `*`, `Create`, `Observe`, `Update`, `Delete`, `LateInitialize`
- **AI Status Fields**: `performanceMetrics`, plus `observedInstanceClass` and `observedInstanceStatus` (the convergence gate)

## Scaling Decision Process

### Input: CloudWatch Metrics
```yaml
performanceMetrics:
  metrics:
    CPUUtilization: { value: 1.98, unit: "Percent" }
    DatabaseConnections: { value: 0, unit: "Count" }
    FreeStorageSpace: { value: 2775404544, unit: "Bytes" }
```

### AI Analysis Thresholds

Scale UP one step when any of: CPUUtilization > 80, DatabaseConnections > 80% of
the class limit, FreeableMemory under 15% of class memory.

Scale DOWN one step only when ALL of: CPUUtilization < 20, DatabaseConnections
< 30%, FreeableMemory above 60%.

Both directions require the convergence gates first: `observedInstanceClass`
equals `spec.parameters.instanceClass` and `observedInstanceStatus` is
"available". There is no IOPS rule and no memory-optimised class switch - the
progression is linear through db.t3.micro/small/medium/large.

### Output: always one line of JSON

**No action does NOT mean empty output.** The model restates the class the
resource already has, with no annotations. An identical server-side apply does
not bump `resourceVersion`, so it is still a genuine no-write and the watch
settles - verified over 4 minutes in
`tests/e2e-local/results/loop-stability-v2-contract.txt`.

This replaced an "output nothing at all" contract, which fought how a language
model works and measured 0/9 on the no-action cases at every model size tested.
See `tests/e2e-local/results/README.md`.

A scaling decision produces one line of JSON, which Crossplane
server-side-applies:

```json
{"apiVersion":"aws.platform.upbound.io/v1alpha1","kind":"SQLInstance","metadata":{"name":"my-db","namespace":"database-team","annotations":{"intelligent-scaling/reasoning":"CPU 94% sustained above 80%"}},"spec":{"parameters":{"instanceClass":"db.t3.small"}}}
```

The model cannot write `status` - it is a subresource an Operation patch does not
reach. That is why the previously declared `status.claudeDecision` was never
populated by anything and has been removed.

## Production Usage Patterns

### AI-Powered Database Deployment
Use `apis/composition-rds-metrics.yaml` for metrics collection. It needs AWS
credentials only - there is no model credential in the composition, because
inference happens in the WatchOperation.

### Operations-Based Scaling
Deploy with `up project run`, which picks up `operations/` automatically. Scaling
is event-driven, not scheduled: the WatchOperation fires on any change to a
`SQLInstance` labelled `scale: me`. There is no cron schedule to tune.

### Monitoring and Observability
- **Scaling Decisions**: the `intelligent-scaling/reasoning` annotation on real scaling events, plus retained Operation objects
- **Performance Metrics**: Available in `status.performanceMetrics`
- **Audit Trail**: Full reasoning preserved for compliance
- **Cost Tracking**: ~$0.00475 per decision on claude-haiku-4-5 (~3,250 in /
  ~300 out, one call). The old $0.06-0.12 figure was Sonnet-era and wrong by an
  order of magnitude. Self-hosted has no per-decision cost; see `COST.md` for
  the crossover, and note that decision quality - not throughput - is the
  binding constraint.
- **Connection Secrets**: Available at `{sqlinstance-name}-connection` in same namespace

## Critical Implementation Notes

### UNFIXED: it over-scaled a real database, with no threshold met

Measured against real AWS, not synthetic data. See
`tests/e2e-local/results/aws-cloud-run.md`.

A real RDS `db.t3.micro` at **CPU 29.67%, 0 connections, 205 MiB freeable
(20.0% of the class's 1 GiB)** was scaled to `db.t3.small`. None of the
prompt's up-conditions were met - the thresholds are CPU > 80, connections >
80%, freeable < 15%. Crossplane applied the patch and **AWS really resized the
instance**. The same resource also got two `db.t3.micro` decisions, so it is
unstable, and the patches carried no `intelligent-scaling/reasoning`
annotation, which the prompt requires for an action - so the audit trail is
empty for the one event that needed it.

The offline eval scores this model 79% correct / 0% over-scaled. That is not
wrong, it is measured on inputs that are too kind: the synthetic cases use
`FreeableMemory: 800000000` (~75% of a micro), comfortably clear of the 15%
boundary.

**The likely root cause is a rule the prompt cannot support.** "FreeableMemory
under 15% of class memory" requires the class-to-memory mapping - that
`db.t3.micro` is 1 GiB - and nothing in the prompt provides it. The model must
recall AWS instance specs and then divide. 205 MiB reads low in absolute terms.

Do not run this unattended against real databases yet. The fixes it argues for,
in order:

1. Have the composition compute `freeableMemoryPercent` and
   `connectionsPercent` into `status.performanceMetrics`, so the model compares
   two numbers rather than recalling hardware specs.
2. Gate the patch on a deterministic threshold check. The model is useful for
   judgement; it should not be the only thing between a metric and a billable
   resize.
3. Reject a scale-up that carries no reasoning annotation.
4. Add near-threshold cases to `tests/scale/cases.json`, derived from a real XR.

### `concurrencyPolicy: Forbid` does not bound concurrency per resource

Also measured on the real run. Three Operations targeting the *same*
SQLInstance ran simultaneously - RDS going available, metrics landing and the
gates populating each spawned one. They oversubscribed the engine's shared KV
cache and wedged in `PipelineRunning` for 8+ minutes producing nothing.

Engine sizing is the other half: `n_slots = 4, n_ctx_slot = 8192,
kv_unified = true` is one 8,192-token cache across four slots, and a real XR
renders to ~3,200 prompt tokens (vs ~2,710 synthetic), so three concurrent
requests need ~9,600. `platform/cpu-fleet/` now sets `--ctx-size 16384`; the
same Operations then completed.

### The model can patch the wrong resource (guarded since v0.3.9-selfhosted-fixes-2)

Measured on the live rig, not theoretical. Under concurrent load the model
sometimes copies a **few-shot example's `metadata.name` and `namespace`** out of
the prompt instead of the watched resource's, and Crossplane server-side-applies
it as returned:

```
{"kind":"SQLInstance","metadata":{"name":"db-d","namespace":"team-y",...},
 "spec":{"parameters":{"instanceClass":"db.t3.small"}}}
cannot apply desired resource: namespaces "team-y" not found
```

Five of eight Operations did this at 8-way concurrency; zero of two did it
sequentially. It failed safe only because `team-y` does not exist on the test
rig - **on a fleet where that name exists, it would resize another team's
database.** Nothing currently validates that the returned identity matches the
watched resource.

Root cause of the concurrency trigger is engine capacity, not the prompt: the
CPU engines run `n_slots = 4, n_ctx_slot = 8192, kv_unified = true` - one
8,192-token KV cache shared across four concurrent requests - while a real
watched `SQLInstance` renders to ~2,710 tokens. Four concurrent requests need
~10,840 and the engine returns `500 Context size has been exceeded`.

**Fixed in `xpkg.upbound.io/solutions/function-openai:v0.3.9-selfhosted-fixes-2`**
(branch `fix-selfhosted-issues`). The operation path now compares the returned
resource's group, kind, namespace and name against the watched resource and
refuses to apply a mismatch: `FunctionSuccess=False`, reason
`ResourceIdentityMismatch`, a warning event naming both identities, and no
desired resources. The API *version* is excluded from the comparison, since two
versions of one kind are the same object.

It refuses rather than rewriting the identity to match: a decision reasoned
about the wrong resource cannot be trusted to carry the right instance class
either.

Verified on the live rig, both directions, using the mock engine's
`foreign-resource` mode (a real model cannot be made to misbehave on demand):

- foreign reply -> refused, and **no** `cannot apply desired resource` event,
  where previously Crossplane attempted the apply
- legitimate reply for the watched resource at CPU 95 -> still applied,
  `db.t3.micro` -> `db.t3.small`

Raising `--ctx-size` or lowering `--parallel` on the engine reduces how often
the model misbehaves; only this guard bounds the damage when it does. Both are
still worth doing - see `tests/e2e-local/results/cpu-fleet-e2e-run-v040.md`.

**Known gap:** a refused patch still leaves the Operation reporting
`Succeeded=True`, because the function returns a condition rather than a fatal
result. The damage is prevented but a fleet operator watching
`kubectl get operation` sees green. The signal is the warning event. Making it
fatal would surface it and trigger the retry budget; that is a deliberate open
choice, not an oversight.

Related, and also unfixed: the model **misses scale-ups near the threshold** -
CPU 85 was left at `db.t3.micro`, consistent with the eval's measured 21% miss
rate. Pair the model with a deterministic threshold check.


### AI Function Configuration
- **No tools on the wire**: with no MCP tools configured, langchaingo omits `tools` (it is `json:"tools,omitempty"`), so the engine needs no tool-calling flags. The OpenAI-functions agent then returns the model's content verbatim instead of demanding a formatted `Final Answer:`, which is what makes a small model viable and keeps cost per decision one call.
- **Context Flow**: the whole watched resource is templated into the prompt via `{{ .Resources }}`. function-openai's input schema is only `systemPrompt` and `userPrompt` - model and endpoint come from the Secret. There is no `contextFields`. `maxTokens` exists only in the `fix-selfhosted-issues` build (capped at 1024); published v0.3.9 sends no `max_tokens` at all, which hangs a CPU engine - see `platform/cpu-fleet/README.md`.
- **Bidirectional**: scales down as well as up, but only when all three
  down-thresholds are clear. Thrash is prevented by the convergence gate
  (observed vs desired class), not by refusing to scale down.
- **Schema Validation**: Returns clean desired spec without system fields

### Network Integration
- Requires `configuration-aws-network` for VPC, subnets, and security groups
- Uses label selectors with `networks.aws.platform.upbound.io/network-id` matching

### Secret Management (v2 Pattern)
- Supports both referenced secrets and auto-generated passwords
- **v2 Connection Secrets**: Function manually composes `{name}-connection` Secret in SQLInstance namespace
- Managed resources write raw credentials to `{name}-rds-conn` Secret
- The `gpt` Secret in `crossplane-system` carries the model endpoint as well as
  the token: `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_MODEL`. The name `gpt`
  and the key `OPENAI_API_KEY` are compiled into function-openai. There is no
  `claude` Secret any more.
- AWS credentials are needed in **two** namespaces, key `credentials`, in AWS
  credentials-file format:
  - `crossplane-system/aws-creds` - read by function-rds-metrics, and by
    `examples/clusterproviderconfig-aws-static.yaml`
  - `<XR namespace>/aws-creds` - read by
    `examples/providerconfig-aws-static.yaml`

  **Both ProviderConfig kinds are required.** configuration-aws-network
  composes its managed resources with `providerConfigRef.kind: ProviderConfig`
  (namespaced), so a `ClusterProviderConfig` alone leaves every composed
  resource with *no status conditions at all* - not an error, just silence,
  because no provider claims them. Diagnose with
  `kubectl get managed -n <ns> -o wide`: empty SYNCED/READY columns mean the
  ProviderConfig kind or namespace does not match, not that AWS is slow.

  SSO credentials are temporary - a long run outlives them and fails with auth
  errors that read like provider bugs.

### AWS managed resources must be explicitly activated alongside Modelplane

`platform/05-aws-activation.yaml`, and it fails silently if forgotten.

Modelplane requires Crossplane installed with
`--set-json 'provider.defaultActivations=[]'`. That setting is **global**: with
default activations cleared, no managed resource is active except what a
`ManagedResourceActivationPolicy` names, and Modelplane's own policy names only
`releases.helm.m.crossplane.io` and `objects.kubernetes.m.crossplane.io`. All
994 AWS definitions stay Inactive, their CRDs never appear, and the SQLInstance
composition has nothing to compose against - with no error saying so.

Check with `kubectl api-resources --api-group rds.aws.m.upbound.io`; empty
output means the policy is missing or has not reconciled.

The policy names the two RDS definitions exactly and wildcards
`*.ec2.aws.m.upbound.io`, because configuration-aws-network composes its
resources from an embedded function - the set is generated at runtime, not
declared in its Composition, so it cannot be enumerated. That activates ~104
ec2 definitions rather than all 994.

Not needed without Modelplane: Crossplane's default activations cover
everything there. This is a cost of co-hosting the two, not of either alone.