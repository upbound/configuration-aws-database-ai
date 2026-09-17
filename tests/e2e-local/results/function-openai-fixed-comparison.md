# function-openai: broken vs fixed, same input

Identical input, identical fleet, only the function changed. Seeded a database
at **CPU 37%** with gates clear — the correct answer is *no action*.

| | published v0.3.3 | fixed build (local) | **published fixed build** |
|---|---|---|---|
| decision | `db.t3.small` — **over-scaled** | `db.t3.micro` — correct | **`db.t3.micro` — correct** |
| prompt at engine | **5,167** tokens (HTML-escaped) | **930** tokens | **930** tokens |
| operation | hung in `PipelineRunning` | `PipelineSuccess` | `PipelineSuccess` |
| annotation written on no-op | n/a (it scaled) | none | none |
| `lastScheduleTime` after | n/a | frozen across 3 samples | frozen |

The third column is `xpkg.upbound.io/solutions/function-openai:v0.3.9-selfhosted-fixes`
pulled from the real registry, so it verifies the published artifact rather than
just the local file. Config digest matches the local build.

An 82% prompt reduction, and a database that is no longer scaled for no reason.

## The four fixes

Branch `fix-selfhosted-issues` off **v0.3.9**, which still carried all four -
worth checking before assuming a newer release helps.

1. **`html/template` → `text/template`** (`fn.go`). Every interpolated value was
   HTML-escaped, so `{{ .Resources }}` reached the model with each `"` as
   `&#34;` - unparseable, and 4x larger.
2. **`maxTokens` input field**, default 1024, threaded to `chains.Run`. Without
   a cap a self-hosted engine generates until its context is exhausted;
   llama.cpp logged `decode() failed: Context size has been exceeded` while the
   Operation hung indefinitely. Hosted APIs supply their own default, which is
   why this was invisible.
3. **`stripCodeFence`** handling `json`/`yaml`/`yml`/bare fences, applied in
   `resourceFrom` too. The old helper only matched ` ```yaml ` and never ran on
   the operation path, so a JSON-fenced reply was discarded silently.
4. **No-op vs failure made distinguishable.** Empty reply → `FunctionSuccess=True`
   reason `NoOp`, nothing written. Unparseable → `FunctionSuccess=False` reason
   `UnparseableModelOutput` plus a warning event. Previously both reported
   success, so a model drifting off-format looked exactly like one deciding to
   do nothing.

Every fix is negative-controlled - revert it and its own test fails.

## Building it

```bash
# GO_BUILD_TAG is required; a plain `docker build .` fails on `-tags` with an
# empty value. --load is required too: buildx otherwise exits 0 and leaves the
# image in the builder cache, with nothing in the image store.
docker build . --build-arg GO_BUILD_TAG=default --tag=function-openai-runtime:fixed --load
crossplane xpkg build -f package \
  --embed-runtime-image=function-openai-runtime:fixed \
  -o package/function-openai-fixed.xpkg
```

## Published build

```
xpkg.upbound.io/solutions/function-openai:v0.3.9-selfhosted-fixes
```

Tagged `-selfhosted-fixes` rather than plain `v0.3.9` on purpose: a bare
upstream version number in another org reads as a mirror of the official
release, and this is a four-patch fork. `upbound.yaml` depends on it and the
WatchOperation references it as `solutions-function-openai`.

**This is a fork, and should be temporary.** The four fixes are small and
independently tested; a PR against `upbound/function-openai` would let this
return to an upstream version. The branch is `fix-selfhosted-issues` off v0.3.9.

## Getting it into a local control plane

The section below is only needed for an unpublished build. With the package
above, a normal `up project run` resolves it.


Four approaches that do **not** work, each for a different reason:

| Attempt | Why it fails |
|---|---|
| `kind load` + `packagePullPolicy: Never` | Crossplane resolves package images with its own OCI client, not containerd - it went to Docker Hub and got a 401 |
| `crane push` to the local registry | olareg runs `--api-push=false --store-ro`; blob upload returns 405 |
| pre-populate `/cache/xpkg` | `emptyDir` with a 20Mi limit; the xpkg is 26 MB |
| `host:port` in `spec.package` | rejected: "must be a fully qualified image name" |

What works: olareg serves a **host bind mount** (`--dir=/registry-data`, bound to
`$TMPDIR/up-local-registry/<cluster>`), one OCI layout per repo. Write the
package into it, then add an `ImageConfig` rewrite - the same mechanism
`up project run --local` uses to redirect `xpkg.upbound.io/<org>/*` at the local
registry.

```bash
D="$TMPDIR/up-local-registry/rds-ai-e2e"
docker run --rm -v "$PWD/package:/pkg:ro" -v "$D/merck-poc:/out" \
  quay.io/skopeo/stable:latest copy --dest-oci-accept-uncompressed-layers \
  docker-archive:/pkg/function-openai-fixed.xpkg \
  oci:/out/function-openai-fixed:v0.3.9-fixed

kubectl apply -f - <<'YAML'
apiVersion: pkg.crossplane.io/v1beta1
kind: ImageConfig
metadata:
  name: local-registry-function-openai-fixed
spec:
  matchImages:
  - type: Prefix
    prefix: xpkg.upbound.io/merck-poc/function-openai-fixed
  rewriteImage:
    prefix: rds-ai-e2e-registry:5000/merck-poc/function-openai-fixed
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-openai-fixed
spec:
  package: xpkg.upbound.io/merck-poc/function-openai-fixed:v0.3.9-fixed
YAML
```

Then point the WatchOperation at it:

```bash
kubectl patch watchoperation rds-intelligent-scaling --type json \
  -p '[{"op":"replace","path":"/spec/operationTemplate/spec/pipeline/0/functionRef/name","value":"function-openai-fixed"}]'
```

## What is now demonstrated end to end

The decision path works and decides correctly. Combined with
`cpu-fleet-e2e-run.md`, which covers Modelplane's scheduling, DRA claims,
cross-cluster serving and weighted canary, the whole demo is verified on two
GPU-less kind clusters.

The remaining gap is breadth, not correctness: one case at CPU 37% is verified
here. Run `tests/e2e-local/eval-model.sh` against the live ModelService to
reproduce the full 12-case measurement now that the transport is sound.
