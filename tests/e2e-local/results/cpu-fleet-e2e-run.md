# CPU fleet end-to-end run (Modelplane v0.3.1, published function-openai v0.3.3)

Two kind clusters, zero GPUs. Every Modelplane capability exercised, and the
`html/template` bug reproduced in production.

> **Historical record.** This run used Modelplane **v0.3.1** and the unfixed
> published `function-openai` v0.3.3, which is why the decision below is wrong.
> The bugs are fixed and the rig now runs Modelplane v0.4.0 - see
> [`cpu-fleet-e2e-run-v040.md`](cpu-fleet-e2e-run-v040.md). Kept because the
> reproduced failure is the evidence for why the canary exists.

## What Modelplane did, verified

| Capability | Evidence |
|---|---|
| Fleet scheduling (CEL device match) | `ReplicasScheduled=True — Scheduled 1 of 1` for both deployments |
| DRA ResourceClaim binding | claims allocated to `gpu-0` and `gpu-1`, driver `gpu.example.com`, on a GPU-less node |
| Cross-cluster serving stack | `InferenceCluster cpu-local` Ready; 10/10 Helm releases Ready on the workload cluster |
| Pool surfacing | `status.gpuPools`: `cpu-synthetic`, 1 node, claimable DRA device |
| Health-gated endpoints | `ModelEndpoint` composed only once a `ModelReplica` went Ready — the challenger appeared first, the incumbent followed |
| Weighted canary | composed HTTPRoute: `scaler-incumbent weight=9`, `scaler-challenger weight=1` |
| Unified endpoint | `http://172.19.255.200/ml-team/rds-scaler` — 10/10 probes answered |
| Two-hop routing | control-plane Traefik `.200` → per-replica Envoy `.100` on the workload cluster |

Nothing about Modelplane blocked this once it had two clusters.

## The decision was wrong, and it reproduced the offline eval exactly

Seeded a database at **CPU 37%**, well under the 80% threshold. Correct answer:
no action. What happened:

```
WANT: db.t3.small    <- scaled up
GOT:  db.t3.micro
CPU:  37
```

The engine logged `n_tokens = 5167` for a prompt that should be about 1,200.
That is `function-openai`'s `html/template` bug: every `"` became `&#34;`, the
JSON was unparseable, and the model over-scaled a database that needed nothing.

This is the same failure the offline eval measured
(`qwen2.5-1.5b-q4.txt`: 67% over-scaling on the old prompt), now reproduced
through the real control plane. It is the expensive direction of error - it
spends money on RDS - and it is exactly what a 10% canary exists to catch
before it reaches the whole fleet.

## Two function-openai bugs, both in published v0.3.3

**No `max_tokens` sent.** The engine generates until it exhausts its context.
llama.cpp logged `decode() failed: Context size has been exceeded` while the
Operation hung in `PipelineRunning` indefinitely. Worked around at the engine
with `--n-predict 256`, which is client-independent; after that the Operation
returned `PipelineSuccess`.

**`html/template` instead of `text/template`** (`fn.go:22`). Inflated the prompt
~4x here and corrupted the JSON. One-line fix plus a negative-controlled
regression test is on the `fix-html-template` branch.

They compound: the mangled prompt makes the model ramble, which makes the
missing `max_tokens` fatal rather than merely wasteful.

## Honest limit of this run

**Transport verified, judgement not.** The chain
WatchOperation → function-openai → weighted ModelService → engine works end to
end. But the model never received valid JSON, so this run says nothing about
whether the prompt and model decide correctly. That needs `fix-html-template`
published, after which the v2 prompt's measured 79% correct / 0% over-scaling
should be reproducible here.
