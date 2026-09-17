# CPU fleet: Modelplane deploying and canarying scaling models, no GPU

Modelplane deploys the models here, schedules them, and fronts them with one
weighted endpoint — on a laptop, for $0. The only thing missing versus a real
GPU fleet is the GPUs.

## Why this works without a GPU

Modelplane will not place a model on a node with no *claimable* device. The
`ModelDeployment` XRD enforces `self.members.exists(m, has(m.nodeSelector))`,
and the fleet scheduler rejects an engine none of whose members resolve a
claimable device. `claim: Synthetic` counts for matching but is never claimed,
so it does not satisfy that check.

So a DRA driver has to publish something. `kubernetes-sigs/dra-example-driver`
publishes **fake** `gpu.example.com` devices on GPU-less nodes, the engine's
ResourceClaim binds, and the entire scheduling path runs: the scheduler, DRA
claims, `ModelReplica` → `ModelEndpoint` → `ModelService` composition, weighted
routing, the scale subresource.

This is a supported configuration, not a workaround — Modelplane runs its own
end-to-end suite this way (`e2e/dra-example-driver.yaml` upstream, vendored here
as `00-dra-example-driver.yaml`).

Cloud provisioning stays GPU-only: `provisioning.eks` forces the NVIDIA AMI and
a `nvidia.com/gpu` taint, which is why this uses `source: Existing`.

## The demo

Two models behind one endpoint, 90/10. The incumbent is the model that measured
best on real scaling decisions; the challenger is one that measured badly, on
purpose — a canary is only worth showing if it can catch something.

| | Model | Measured on real decisions |
|---|---|---|
| incumbent, 90% | Qwen2.5-1.5B-Q4 | 79% correct, **0% over-scaling** |
| challenger, 10% | Qwen2.5-0.5B-Q4 | 0% correct, **38% over-scaling** |

Numbers from [`tests/e2e-local/results/`](../../tests/e2e-local/results/).

1. **Deploy both.** The `WatchOperation` is pointed at one URL and knows nothing
   about how many models sit behind it.
2. **Measure.** `tests/scale/agreement.sh` against the live endpoint. The
   challenger scales databases that need nothing — the failure that costs money.
3. **Roll back** by editing one weight. Effective on the next decision. No
   manifest change in the configuration, no Secret change, no restart.
4. **Or promote**, the same way, in the other direction.

That is the argument for a platform over a bare vLLM Deployment: you cannot know
which model fits your task without measuring it against real decisions, and this
lets that experiment run on a slice you choose instead of a cutover you hope
goes well.

## Run it

Needs **two kind clusters** (see caveats - one does not work), roughly
**10-12 GiB across the pair**, and Kubernetes **1.34+** on the workload cluster
(GA `resource.k8s.io` DRA APIs).

Check what Docker is actually allowed to use, not what the machine has. Docker
Desktop defaults to about half of physical RAM, and `docker stats` reports that
allocation - so a 32 GB machine can look like a 16 GiB one and OOM at 10 GiB
used:

```bash
sysctl -n hw.memsize | awk '{printf "physical: %.0f GB\n", $1/1e9}'
docker info --format '{{.MemTotal}}' | awk '{printf "docker:   %.1f GiB\n", $1/1024/1024/1024}'
```

Raise it in Docker Desktop under Settings -> Resources -> Memory, leaving the
host 8-10 GiB.

To do it from the command line, the ORDER MATTERS. Docker Desktop writes its
in-memory settings back to disk on shutdown, so editing the file while it is
running silently reverts on the next restart. Stop it first:

```bash
docker desktop stop
until ! docker info >/dev/null 2>&1; do sleep 3; done   # wait for it to be down

python3 - <<'EOF'
import json, io, os
base = os.path.expanduser("~/Library/Group Containers/group.com.docker")
for name, key in (("settings-store.json", "MemoryMiB"), ("settings.json", "memoryMiB")):
    p = os.path.join(base, name)
    if not os.path.exists(p): continue
    d = json.load(open(p)); d[key] = 24576
    io.open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2))
EOF

docker desktop start
docker info --format '{{.MemTotal}}' | awk '{printf "%.1f GiB\n", $1/1024/1024/1024}'
```
Modelplane installs cert-manager, Envoy Gateway, Gateway API CRDs,
kube-prometheus-stack, Node Feature Discovery, LeaderWorkerSet and the NVIDIA
DRA driver (which finds nothing and no-ops) onto the inference cluster. Check
what else is holding memory first — other kind/k3d clusters are easy to forget:

```bash
docker stats --no-stream --format '{{.MemUsage}}\t{{.Name}}' | sort -hr | head
```

Then:

```bash
# Modelplane itself, with its ~14 unused cloud providers kept dormant.
# Apply the trim BEFORE the Configuration - an ImageConfig runtime binds at
# ProviderRevision creation.
kubectl apply -f platform/00-prerequisites.yaml
kubectl apply -f tests/e2e-local/lean-providers.yaml
kubectl apply -f platform/10-configuration.yaml
kubectl wait --for=condition=Healthy configuration.pkg.crossplane.io/modelplane --timeout=20m

# ImageConfig binds at ProviderRevision creation, so if provider-helm installed
# first it came up without the RBAC the prerequisites grant.
kubectl patch provider.pkg.crossplane.io upbound-provider-helm --type merge \
  -p '{"spec":{"runtimeConfigRef":{"name":"provider-helm-modelplane"}}}'

# Gateway, with a MetalLB pool derived from the real kind subnet.
tests/e2e-local/apply-inference-gateway.sh

# DRA driver, node labels, kubeconfig Secret - all three fail silently if skipped.
platform/cpu-fleet/setup.sh rds-ai-e2e cpu-synthetic

# Then follow the order setup.sh prints.
```

## Two more traps with two clusters

**`up project run --local` rewrites the kubeconfig and can drop other kind
contexts.** Create the workload cluster, then the control plane, and the
workload context may be gone. Restore it with
`kind export kubeconfig --name <workload>` - the cluster itself is fine, only
the kubeconfig entry was lost.

**`kind export kubeconfig` also switches the current context.** Anything running
with bare `kubectl` then silently queries the wrong cluster. This cost me a
confusing reading where a healthy control plane reported zero providers, because
a background poller had been repointed at the workload cluster mid-run. Use
`kubectl --context <name>` everywhere once a second cluster exists;
`setup.sh` does, and so should anything you script around it.

**The canary weights are on the CONTROL plane, not the workload cluster.** There
are HTTPRoutes on both, and only one of them carries weights:

| cluster | HTTPRoute | backends |
|---|---|---|
| control plane | `ml-team/rds-scaler-<hash>` | both pools, `weight: 9` and `weight: 1` |
| workload | `default/scaler-{incumbent,challenger}-<hash>` | one pool each, no weight |

The per-replica routes have a single backend, so a weight would be meaningless
and the field is absent. Checking the workload cluster therefore "finds" no
canary. Worse, a query that defaults an absent weight to 1 - `.weight // 1` in
yq or jq - reports `weight=1` on both and looks like a 50/50 split rather than a
missing field. Verify on the control plane, and print absent as absent:

```bash
kubectl get httproute -n ml-team -l crossplane.io/composite=rds-scaler \
  -o json | yq e -p=json '.items[].spec.rules[].backendRefs[]
    | .name + " weight=" + (.weight // "ABSENT" | tostring)' -
```

## Five function-openai bugs that bite a self-hosted engine

All five were found running this, and all five are fixed in the build this
configuration uses:
`xpkg.upbound.io/solutions/function-openai:v0.3.9-selfhosted-fixes-2`. The first
four are in published v0.3.3 and v0.3.9; the fifth is a safety bug that only
shows up against a self-hosted engine under load.

**1. It builds prompts with `html/template`, not `text/template`** (`fn.go:22`).
Every interpolated value is HTML-escaped, so `{{ .Resources }}` arrives with
each `"` turned into `&#34;`. Measured here: a prompt that should be ~930
tokens arrived at ~5,167, and the JSON is unparseable, so the model rambles
instead of emitting a short object and stopping - which makes bug 2 far worse.

**2. It sends no `max_tokens`.** The engine therefore generates until it
exhausts its context window. On a GPU that is merely wasteful; on CPU the
Operation hangs in `PipelineRunning` indefinitely and llama.cpp logs:

```
decode() failed: Context size has been exceeded.
```

The fix adds a `maxTokens` input capped at a `defaultMaxTokens` of 1024. Belt
and braces, fix it at the engine too, which works regardless of the client:
`--n-predict 256` is set on both ModelDeployments here.

**3. It strips markdown fences on the composition path only, and only
` ```yaml `.** The Operation path (`resourceFrom`) did not strip at all, so a
fenced reply failed to parse silently. Small models fence their output
constantly. The fix routes both paths through one `stripCodeFence` that handles
` ```json `, ` ```yaml `, ` ```yml ` and bare ` ``` `.

**4. A parse failure was indistinguishable from a no-op.** Both produced an
empty result and a successful-looking Operation. The fix splits them: an empty
reply is `FunctionSuccess=True` reason `NoOp`; unparseable output is
`FunctionSuccess=False` reason `UnparseableModelOutput` plus a warning event.
Without this, a model quietly failing to emit JSON looks exactly like a model
correctly deciding to do nothing - and on this workload most decisions *are*
no-ops, so the failure hides in the majority case.

**5. It applied the model's output to whatever resource the model named.** Under
concurrent load a small model copies a few-shot example's `name` and `namespace`
out of the prompt instead of reading the watched resource, and Crossplane
server-side-applies it as returned. Measured here: 5 of 8 Operations, 0 of 2
sequentially. It failed safe only because the example's namespace did not exist
on the rig - on a real fleet it resizes another team's database.

The fix compares group, kind, namespace and name against the watched resource
and refuses a mismatch (`FunctionSuccess=False`, reason
`ResourceIdentityMismatch`, nothing applied). Version is excluded, since two
versions of one kind are the same object. The engine-side mitigations are
worth doing too - `--ctx-size` >= `n_slots` x prompt size, or `--parallel 1-2`,
because the trigger is a KV cache oversubscribed by concurrent requests - but
only the guard bounds the damage.

Verify it with the mock rather than a real model, which cannot be asked to
misbehave on demand:

```bash
kubectl -n mock-model set env deploy/mock-engine MOCK_MODE=foreign-resource
```

All five fixes carry regression tests and are worth upstreaming; they currently
live on `fix-selfhosted-issues` off v0.3.9. Details and the verification runs
are in
[`tests/e2e-local/results/cpu-fleet-e2e-run-v040.md`](../../tests/e2e-local/results/cpu-fleet-e2e-run-v040.md).

## Modelplane v0.4.0 has to be installed fresh

This configuration pins **v0.4.0**, the current release. Install it on a control
plane that has never had v0.3.1. Note that `setup.sh` does not do this for you -
it prepares and registers the *workload* cluster only. The control plane's
Crossplane install and `platform/10-configuration.yaml` are the README's Tier 3
steps, and they have to land on a fresh cluster.

Upgrading an existing v0.3.1 install in place does not work. All fourteen
Modelplane XRDs add a category to `spec.names` in v0.4.0:

| category added | XRDs |
|---|---|
| `infrastructure` | aks/eks/gke/nebius/vultr clusters, servingstacks |
| `platform` | inferenceclasses, inferenceclusters, inferencegateways |
| `models` | modelcaches, modeldeployments, modelendpoints, modelreplicas, modelservices |

`spec.names` on a CompositeResourceDefinition is immutable, so Crossplane cannot
reconcile the existing XRDs. The new revision goes Active and stays
`Healthy=False` with `reason: UnhealthyPackageRevision`:

```
cannot establish control of object: CompositeResourceDefinition
"aksclusters.infrastructure.modelplane.ai" is invalid:
spec.names: Invalid value: "object": Value is immutable
```

This does not clear on retry. Completing the upgrade in place means deleting all
fourteen XRDs, which deletes every composite they own - InferenceClusters,
ModelDeployments, ModelServices and the fleet they run.

Two things about this are easy to get wrong, both of which cost time here:

- **The failed revision is inert, not destructive.** Throughout the stall the
  running fleet kept serving: both ModelDeployments stayed Ready and the canary
  endpoint answered HTTP 200. Nothing is on fire, which is precisely why it is
  tempting to wait it out. Waiting does not help.
- **`Healthy=True` on an *Inactive* revision means nothing.** An Inactive
  revision reports healthy because it is not establishing control of anything.
  Reverting the pin to v0.3.1 and seeing the v0.4.0 revision go
  `Inactive healthy=True` is not the upgrade recovering - check the *Active*
  revision.

Downgrading is not an escape hatch either. Modelplane's embedded composition
functions are pinned by digest, so an older Configuration cannot reinstall over
a newer one:

```
existing package modelplane_compose-inference-cluster@sha256:953b005...
is incompatible with constraint sha256:a880d9fc...
```

Once a control plane has seen v0.4.0, the way out is forward or fresh.

**Nothing in `platform/cpu-fleet/` needed changing for v0.4.0.** Diffing the two
packages' XRD schemas for the kinds used here:

| kind | v0.3.1 -> v0.4.0 |
|---|---|
| `InferenceClass` | identical |
| `ModelService` | identical |
| `ModelDeployment` | description text only, no field changes |
| `InferenceCluster` | adds `spec.stack` |

`spec.stack` selects the serving layer - `Standard` (Modelplane's own:
Deployment/LeaderWorkerSet, Gateway API, endpoint picker) or `Dynamo` (NVIDIA's
Grove + KAI gang scheduler + ModelExpress weight distribution). It defaults to
`Standard` and carries `self == oldSelf`, so it is immutable once set.
`20-inference-cluster.yaml` leaves it unset and gets `Standard`, which is what
this demo wants.

The `ServingStack` XRD changed more, though nothing here sets it directly - it
is composed by `InferenceCluster`. It drops `versions` (per-component version
pinning is no longer user-overridable) and `nvidiaDriverRoot`, and gains `cloud`
and `stack`.

The AWS provider pins (v2.6.0) and the Crossplane requirement (`>=v2.3.0`) are
unchanged from v0.3.1.

## Known caveats

**TWO CLUSTERS ARE REQUIRED. One cluster does not work.** Tested, and it fails
definitively:

```
failed to install CRD crds/gatewayapi-crds.yaml: conflict occurred while
applying /referencegrants.gateway.networking.k8s.io: conflict with
"apiextensions.crossplane.io/composed/0a047b94...":
.metadata.annotations.gateway.networking.k8s.io/channel
```

The control-plane `InferenceGateway` (Traefik) composes the Gateway API CRDs.
The `ServingStack` for an inference cluster installs them again via Envoy
Gateway's Helm chart. On separate clusters that is fine — each owns its own
copy. Pointed at the same cluster, the second install hits a server-side-apply
field-ownership conflict on
`.metadata.annotations.gateway.networking.k8s.io/channel`, the `gateway-helm`
release never goes Ready, and the `InferenceCluster` sits at
`Ready=False  Unready resources: serving-stack` forever.

There is no clean workaround: two Crossplane-composed owners want the same CRD
field, so forcing it would just flap between reconcilers.

So `setup.sh` must capture the kubeconfig of a **second** kind cluster, not the
control plane's own. Modelplane's e2e does exactly this, and states it "assumes
exclusive ownership" of each inference cluster - that ownership claim is load
bearing, not advisory.

Budget accordingly: the control plane runs Crossplane, Modelplane and Traefik;
the workload cluster runs the serving stack (cert-manager, Envoy Gateway,
kube-prometheus-stack, NFD, LeaderWorkerSet, the NVIDIA DRA driver) plus the
models. Measured ~9.5 GiB when one cluster tried to hold both, so plan for
roughly 10-12 GiB across the pair.

**No weight cache.** The XRD rejects `volumes` in the container template, so
each pod re-downloads its weights on restart. A `ModelCache` would fix it but
needs an RWX StorageClass, which kind's default `local-path` is not.

**Do not use Modelplane's `e2e/lean-control-plane.yaml` here.** It matches the
prefix `provider-aws-`, which also catches `provider-aws-rds` — the provider
this configuration composes RDS instances through. An ImageConfig runtime
overrides even an explicit `runtimeConfigRef`, so it would scale the RDS
provider to zero and the demo would stop working with no obvious cause. Use
`tests/e2e-local/lean-providers.yaml`, which names the AWS families
individually.
