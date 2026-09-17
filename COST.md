# Cost model

Why this file exists: the case for serving the scaling model ourselves is an
economic one, and it is easy to make dishonestly. This records the assumptions,
separates **measured** numbers from **estimates**, and shows where the crossover
actually falls.

> **Status: the throughput rows are still estimates.** Every number marked
> ESTIMATE is derived from hardware characteristics and published pricing, not
> from this system running. `tests/scale/` exists to replace them. Treat the
> conclusions as directional until it has.
>
> **Decision quality is now partly measured, and it is the binding constraint.**
> A 0.5B model scored 0/24 correct and over-scaled 38% of the time - see
> "What must be measured" below. Every cost advantage here assumes the
> self-hosted model makes the same decisions as the hosted one. Establish that
> before quoting any ratio.

## The argument in one paragraph

The previous design made one decision per database per minute on a hosted model.
That cadence was not a design choice - it was a rate limiter for API spend, as
was the annotation-age arithmetic that used to live in the prompt. Both are gone
now. The interesting consequence is not a smaller bill at the old cadence; it is
that **responsiveness stops costing money**. A hosted frontier model makes
sub-15-second reactive scaling economically impossible at any fleet size. A
self-hosted 8B makes it merely expensive.

## Assumptions

### Hosted baseline (claude-haiku-4-5)

| Input | Value | Source |
|---|---|---|
| Price in / out | $1 / $5 per MTok | Published pricing. VERIFY at time of writing. |
| Prompt tokens in | ~3,250 | ESTIMATE, and likely HIGH. A first measurement against a minimal synthetic resource showed ~1,190 tokens (llama.cpp `n_tokens`), of which ~680 is the static prompt. A production XR carries more - annotations, conditions, resourceRefs, a fuller spec - so the real figure sits between the two. Measure it before quoting any of the tables below. |
| Tokens out | ~300 | ESTIMATE. A one-line JSON patch, or nothing. |
| LLM calls per decision | 1 | With no MCP tools configured the agent makes a single call and returns the reply verbatim. VERIFY against the measured call count. |
| **Cost per decision** | **~$0.00475** | Derived. |

A note on why this is a constant rather than a range. `function-openai` wraps
the model in `agents.NewOpenAIFunctionsAgent(..., WithMaxIterations(20))`, so in
principle a decision could cost up to 20 calls. With zero tools resolved it
cannot: langchaingo builds an empty function list, the request field is
`json:"tools,omitempty"` so `tools` never reaches the wire, and `ParseOutput`
treats a reply with no tool call as a finish - returning the content verbatim.
One call in, one out. `tests/scale/` should still confirm this empirically,
because it is the assumption the whole hosted-side baseline rests on.

### Self-hosted platform (Modelplane on EKS)

| Line item | Monthly | Notes |
|---|---|---|
| EKS control plane | ~$73 | $0.10/hr. Unavoidable per inference cluster. |
| System node group | ~$140 | `m6i.xlarge` x1. **Modelplane creates this itself** (`compose-eks-cluster/function/fn.py`, `_SYSTEM_POOL_INSTANCE_TYPE`). Easy to forget. |
| GPU node | ~$587 | `g6.xlarge`, 1x NVIDIA L4, us-west-2 on-demand. |
| NAT / EBS / transfer | ~$60 | ESTIMATE. |
| **Total, 1 replica** | **~$860** | Each added replica is **+$587**, a step, not a slope. |

No spot: Modelplane's `nodePools` exposes only
`capacityBlock.capacityReservationId`, with no `capacityType`.

Ceiling: `ModelDeployment.spec.replicas` maxes at **10** and `engines` at 8. Past
~10 L4s you need multiple ModelDeployments behind one ModelService, or a larger
GPU class.

### Throughput per L4 — ESTIMATE, the weakest link

| Input | Value |
|---|---|
| Model | Qwen3-8B, FP16, `--max-model-len=8192` |
| Weights | ~16 GB of the L4's 23 GB reported VRAM |
| Prefill | ~2,000-4,000 tok/s aggregate |
| Decode | ~300-600 tok/s aggregate |
| GPU time per decision | ~1.5-2.5 s |
| **Decisions per month** | **~1.0-1.7M** |

Because weights eat most of the card, **KV cache is what caps concurrency**, and
concurrency is what the whole fleet argument rests on. Switching to
`Qwen/Qwen3-8B-AWQ` cuts weights to ~6 GB and frees the rest for KV cache. That
is the single highest-leverage change available and it should be settled by
measurement, not argument.

## Break-even

Break-even decisions/month = $860 / $0.00475 ≈ **181,000**.

| Cadence | Decisions/db/mo | Hosted $/db/mo | Break-even fleet | Databases per L4 |
|---|---|---|---|---|
| every 10 min | 4,320 | ~$21 | ~42 | ~300 |
| every 1 min | 43,200 | ~$205 | ~4 | ~30 |
| every 30 s | 86,400 | ~$410 | ~2 | ~15 |
| every 10 s | 259,200 | ~$1,231 | **1** | ~5 |

The band between break-even and saturation is where this pays off. Below it you
are paying for an idle GPU; above it you add a $587 step.

## At fleet scale

Every-10-minute cadence:

| Fleet | Hosted | Self-hosted | Ratio |
|---|---|---|---|
| 100 dbs | ~$2,052 | ~$860 (1 L4) | 2.4x |
| 500 dbs | ~$10,260 | ~$1,447 (2 L4) | 7.1x |
| 1,000 dbs | ~$20,520 | ~$2,621 (4 L4) | 7.8x |

Every-10-second cadence, the thing that is only affordable self-hosted:

| Fleet | Hosted | Self-hosted | Ratio |
|---|---|---|---|
| 10 dbs | ~$12,312 | ~$1,447 (2 L4) | 8.5x |
| 100 dbs | ~$123,120 | ~$12,013 (20 L4) | 10.2x |

## The ROI framing, which matters more

Comparing two inference bills understates the case. The point of the system is
eliminating over-provisioning.

1,000 x `db.t3.micro` is roughly **$12,240/mo** of RDS. If right-sizing recovers
20%, that is **~$2,448/mo saved**:

- Self-hosted decisioning at ~$2,621/mo roughly **pays for itself**.
- Hosted at ~$20,520/mo costs **8.4x more than the waste it eliminates**.

At fleet scale a hosted frontier model can cost more than the problem it solves.

## What must be measured before trusting any of this

`tests/scale/` should produce, and this file should then carry:

1. **Tokens in/out per decision** - replaces the ~3,250/~300 estimate, which a
   first measurement suggests is high (see above). Every dollar figure in this
   file scales linearly with it, so this is the highest-leverage number here.
   Note that `function-openai` currently HTML-escapes the interpolated resource
   (`html/template` at fn.go:22), inflating it ~1.3x for nothing - measure with
   that fixed, or you will bake the bug into the model.
2. **Decisions/sec at concurrency 1 / 8 / 32 / 128** against the ModelService,
   with p50 and p99. Replaces the ~1.0-1.7M/mo figure.
3. **GPU utilization and KV-cache pressure** at each concurrency, and the same
   run against `Qwen3-8B-AWQ` to settle the FP16-vs-AWQ question.
4. **Decision agreement rate vs claude-haiku-4-5** on identical inputs.
   Without this the comparison is dishonest: it prices two things that are not
   established to be equivalent. Report agreement, and characterize the
   disagreements.

   **Measured, and it rules out the small-model-plus-prompt design entirely.**
   Both models on `tests/scale/cases.json` via `tests/e2e-local/eval-model.sh`,
   2 repeats, temperature 0:

   | | Qwen2.5-0.5B-Q4 | Qwen2.5-1.5B-Q4 |
   |---|---|---|
   | correct decisions | 0 / 24 (0%) | 4 / 24 (**17%**) |
   | **over-scaled** (costs money) | 9 (38%) | 16 (**67%**) |
   | malformed, no patch (safe) | 10 (42%) | 2 (8%) |
   | right action, wrong class | 5 (21%) | 2 (8%) |

   **Scaling the model up made it more dangerous, not safer.** Split the cases
   by what they actually required:

   | | action warranted (3 cases) | no action warranted (9 cases) |
   |---|---|---|
   | 1.5B correct | 2 | **0** |

   The 1.5B picks the right instance class when scaling is genuinely needed. It
   failed *every* gate case, including "already at the largest class", where it
   tried to scale past `db.t3.large`. What improved between 0.5B and 1.5B was
   JSON formatting, not judgement - and formatting without judgement is worse,
   because the 0.5B's malformed replies emitted no patch and were accidentally
   safe.

   **Then the prompt was fixed, and most of it went away.** Same 1.5B model,
   same cases, only the prompt changed
   (`tests/e2e-local/prompt-variants/v2-fewshot.yaml`):

   | Qwen2.5-1.5B-Q4 | deployed prompt | improved prompt |
   |---|---|---|
   | correct | 17% | **79%** |
   | **over-scaled** (costs money) | 67% | **0%** |
   | missed a needed scale (safe) | 0% | 21% |
   | malformed | 8% | 0% |

   All nine gate cases pass on the improved prompt, and the expensive failure
   mode is gone entirely. Two changes did that, neither of them a bigger model:

   - **A legal way to say "nothing needed."** The deployed prompt demands
     *empty output* for a no-op, which fights how a language model works - it
     wants to answer. Every one of the 0.5B's gate cases came back as prose.
     The variant lets it restate the current class instead; a server-side apply
     of identical content does not bump `resourceVersion`, so it stays a real
     no-write and the watch still settles.
   - **Worked examples**, three of the four showing no-action. The deployed
     prompt is all rules and no demonstrations, and small models imitate far
     better than they follow rules.

   The residual 21% are *missed* scale-ups, not wrong ones. For an autoscaler
   that is the right direction to err: it forgoes a benefit rather than spending
   money, and leaves the database exactly as the operator provisioned it.

   Two consequences that survive the fix:

   1. **Direction of error matters more than accuracy.** 17% correct with 67%
      over-scaling is unusable; 79% correct with 0% over-scaling is usable with
      care. Any quality figure quoted without the direction is close to
      meaningless.
   2. **Prompt engineering beat model size here, decisively.** This was then
      tested directly against the model `platform/` actually deploys:

      | | correct | over-scaled |
      |---|---|---|
      | Qwen2.5-**1.5B** + improved prompt | **79%** | **0%** |
      | Qwen3-**8B** + deployed prompt | 25% | **75%** |
      | Qwen3-**8B** + improved prompt | 67% | 17% |

      The 8B fails all 9 no-action cases on the shipped prompt, exactly as both
      smaller models did. Given the improved prompt it recovers - but still
      lands behind the 1.5B, over-scaling on the two cases where required data
      was absent (it filled the gap; the smaller model read the rule literally
      and declined).

      Sample sizes differ (1.5B n=24, 8B n=12, because 8B CPU inference runs
      about a minute per request), so the defensible claim is not "the 1.5B is
      better" but **"there is no evidence the 8B is better at this task."**
      That is enough to act on: the ~$860/mo L4 in `platform/` buys nothing
      measurable here, and provisioning it before fixing the prompt would have
      spent that money to paper over a prompt bug while still over-scaling 75%
      of the time.

      This is the strongest single argument in this file for measuring before
      buying. It is also a caution about this file's own method: every dollar
      figure above was computed before any of this was measured, and the thing
      that turned out to matter most - decision quality - was the one input
      taken on faith.
5. **Parse-failure rate.** A malformed response now surfaces as
   `FunctionSuccess=False` with reason `UnparseableModelOutput` rather than
   silently looking like "no scaling needed", so this is countable.
6. **No-op rate.** Event-driven decisions only cost when something changed, but
   a no-op still costs a full prefill. If most events are no-ops, a
   deterministic pre-filter ahead of the model is worth more than a faster GPU.

## The architecture this measurement implies

**Read the A/B above first.** An earlier version of this section argued the
gates could not live in the prompt at all, on the strength of 0/9 gate cases at
1.5B. Better prompting took that to 9/9, so the strong claim was wrong: it was a
prompt problem wearing an architecture problem's clothes.

The weaker claim still stands, and is still worth acting on. Even at 79% the
model is only *probably* right, whereas the gates are pure boolean logic over
data the composition already surfaces. Making them deterministic is free
correctness, and it pays for itself twice over on cost:

- A non-LLM step (KCL, or a CEL filter) evaluates the gates it already has the
  data for - `observedInstanceClass` vs `spec.parameters.instanceClass`,
  `observedInstanceStatus`, metrics present, thresholds crossed, headroom in the
  progression. If no action is warranted, **the model is never called.**
- The model is invoked only when action *is* warranted, and asked only to pick
  the target class - the one thing it does reliably.

This is strictly better on three axes at once. Correctness: the 67%
over-scaling failure mode becomes structurally impossible. Cost: no-op events
stop costing a prefill, which is most events on a healthy fleet, and that
changes the throughput maths in this file more than any GPU choice. And loop
stability: the no-op path becomes deterministic code rather than a behaviour we
hope a model exhibits.

It also reopens the small-model question favourably, and the A/B above suggests
it should be: a 1.5B at 0% over-scaling is already in usable territory, and
narrowing its job to "pick the next class up" - the one thing it did reliably
even with the bad prompt - should push it further.
