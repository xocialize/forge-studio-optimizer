# ADR 0004 — SPANV2 vs. Fallback Ladder for the Playback Tier (Phase C.1)

**Date**: 2026-05-26
**Status**: **Superseded by [ADR-0006](0006-phase-c-unfreeze-efrlfn.md) (same day, 2026-05-26 PM)**
**Branch**: `feature/forge-2026-q2-refresh`

> **Superseded same day.** External research delivered 2026-05-26 PM
> ([Docs/Research/research-2026-05-26-three-surveys.md](../Research/research-2026-05-26-three-surveys.md))
> identified EfRLFN (arXiv 2602.11339, MIT, ICLR 2026) as a permissive
> non-NTIRE alternative for the playback tier that doesn't depend on
> SPANV2 weight releases. The 2026-07-15 calendar hold below is no
> longer the gating decision. See **[ADR-0006](0006-phase-c-unfreeze-efrlfn.md)**.
> The SPDX / permissive-license analysis on SPANV2, PDS, PKDSR in §1–§3
> below remains accurate — *adopt nothing yet* is what flipped, not the
> licensing facts.
**Decision gate**: [Forge-CodingPlan-v1.0.md §C.1](../Forge-CodingPlan-v1.0.md)
**License audit**: [Packages/ForgeUpscaler/LICENSES.md](../../Packages/ForgeUpscaler/LICENSES.md)

---

## Context

Phase C of the 2026 Q2 refresh wants SPANV2 (XiaomiMM, NTIRE 2026 ESR 1st place) to replace SRVGGNetCompact in `ForgeUpscaler`'s playback tier. The coding plan §C.1 makes the swap conditional on two gates:

1. A weight release exists.
2. The license is commercial-compatible (Apache 2.0 / MIT / BSD).

A fallback ladder is specified if either gate fails:

1. **PDS** (BOE_AIoT, 2nd place — pruned + distilled SPANF)
2. **PKDSR** (3rd place — progressive KD)
3. Train SPANV2 from scratch from the published architecture (~14 days on M5 Max)

The §2.3 re-evaluation argument for SPANV2 is throughput: the PyTorch reference shows ≥ 1.2× SRVGGNetCompact at equal-or-better quality on CUDA via the `span_attn_op` kernel fusion, with the open question (deferred to the C.4 gate) being whether `mx.compile` recovers that fusion on Metal.

## Decision

**Hold SRVGGNetCompact in the playback tier. Do not begin Phase C.2.** Re-evaluate on **2026-07-15**.

This is **not** a swap-and-revisit decision. The C.1 license gate **cannot be evaluated** on 2026-05-26 because **no weights of any kind are publicly available** for SPANV2 or the two fallback models:

| Candidate          | Code released?               | Weights released?            | License declared? |
|--------------------|------------------------------|------------------------------|-------------------|
| SPANV2 (XiaomiMM)  | No (paper: "available later") | No (only baseline SPAN in `model_zoo/`) | Umbrella repo MIT, but SPANV2 not yet contributed |
| PDS (BOE_AIoT)     | No standalone repo            | No                           | Unknown            |
| PKDSR (3rd place)  | No standalone repo            | No                           | Unknown            |

A premature swap of any of the three would be speculative; falling all the way down to "train from scratch" inside this sprint window is not budgeted. The conservative call is to stay on SRVGGNetCompact until either an upstream weight drop unblocks adoption or the re-evaluation window closes.

## Reasoning

1. **The gate cannot fire without an artifact.** §C.1's acceptance criterion is "License confirmed commercial-compatible OR fallback adopted with rationale." Neither half is satisfiable today: every candidate is in a pre-release state.

2. **Risk #1 in the plan is "SPANV2 weights released non-commercial."** The actual 2026-05-26 risk is one step earlier: **weights not released at all**. The plan's stated mitigation (PDS → PKDSR) presupposes those teams have published artifacts, which they have not.

3. **Risk #6 ("NTIRE 2026 repo doesn't publish weights in time")** is the realized risk. The plan's mitigation for #6 is to train from scratch in 14 days on M5 Max. That is a substantial commitment and should not be invoked until the upstream timeline is clearer.

4. **NTIRE pattern.** Looking at the parallel [NTIRE2025_ESR](https://github.com/Amazingren/NTIRE2025_ESR) repo as a precedent: top-team contributions typically land in `model_zoo/` over the weeks following the CVPRW poster session. CVPR 2026 is mid-June; expecting the XiaomiMM SPANV2 PR to land in `Amazingren/NTIRE2026_ESR` between mid-June and mid-July is reasonable. 2026-07-15 is the right re-evaluation horizon.

5. **The C.4 throughput gate is the bigger architectural risk anyway.** Even if SPANV2 weights drop tomorrow under MIT, the C.4 gate still has to confirm that `mx.compile` recovers enough of the `span_attn_op` fusion advantage on Metal to clear the ≥1.2× throughput threshold. Holding SRVGGNetCompact for six weeks costs the project nothing in terms of shipping risk — the playback tier already meets the §4 acceptance gate (≥30 fps 1080p→4K on M4 Pro) with SRVGGNetCompact.

6. **Architecture spec is sufficient for a *future* port** — but not for this phase. arXiv:2604.03198 describes SPANV2 in enough detail to re-implement (near-pixel branch, 5 × SPABV2 at 32 ch, learned-1×1 attention, depthwise-separable fusion, PixelShuffle ×4). That clears Phase C.2 *implementation* (architecture port without weights). It does **not** clear C.1 — weights are still needed for C.3 / C.4 / C.5.

## License audit summary

See [LICENSES.md](../../Packages/ForgeUpscaler/LICENSES.md) for the full audit with retrieval URLs and dates. Headline:

- **SPANV2**: umbrella repo MIT (good if/when weights land there), but no SPANV2 weights/code in repo. SPDX (umbrella): `MIT`.
- **PDS / PKDSR**: no public repo, no published weights, no SPDX. License posture: undetermined.
- **SRVGGNetCompact (held)**: `BSD-3-Clause` via [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN). No license change.

## Consequences

For the in-flight roadmap:

- **Phase C.2** (SPANV2 MLX-Swift implementation) — **deferred** until C.1 closes. The architecture spec is public; the port can be drafted from the paper alone, but doing so before C.1 would create dead code if upstream publishes a quirky weight layout we have to mirror. Park C.2 until weights exist.
- **Phase C.3** (weight conversion script) — **deferred**; depends on C.2 and on having a target state_dict.
- **Phase C.4** (benchmark vs. SRVGGNetCompact decision gate) — **deferred**.
- **Phase C.5** (integration) — **deferred**; `PlaybackUpscaler.swift` continues to back `ForgeUpscaler.playback`.
- **Phase D** (export tier) — **unaffected.** Real-ESRGAN MLX adoption proceeds independently.
- **Phase E** (QualityRegressor / SigLIP2) — **unaffected.**
- **Phase F** (signage fine-tune) — partially affected; F.2 reads *"Start from SPANV2 (playback) and Real-ESRGAN (export) weights"*. If C.1 stays open beyond F's start, F.2 starts from SRVGGNetCompact (playback) + Real-ESRGAN (export) instead, or holds the playback fine-tune. To revisit when C.1 closes.
- **Pipeline §4 gates** — unaffected. SRVGGNetCompact already clears `playback_4k_fps_min ≥ 30 fps`. The bundle-size gate is not threatened by holding.
- **ForgeUpscaler PRD v0.1 §4.2** ("Engine: SPANV2 (Phase C target) or SRVGGNetCompact (current fallback)") — the current-fallback branch is the one we sit on.

For the LICENSES.md ledger:

- Current state captured: SRVGGNetCompact held under BSD-3-Clause.
- Phase D entries (Real-ESRGAN MLX) will be added by D.1 when that phase audits the themindstudio port.

## Revisit triggers

The decision **must** be revisited if any of the following occurs:

1. **SPANV2 weights publish.** XiaomiMM contributes weights to [`Amazingren/NTIRE2026_ESR/model_zoo/`](https://github.com/Amazingren/NTIRE2026_ESR/tree/main/model_zoo) or releases them through any commercial-compatible channel (MIT / Apache 2.0 / BSD).
2. **PDS or PKDSR publish.** A standalone repo from BOE_AIoT or the PKDSR team appears with a permissive license.
3. **2026-07-15 calendar trigger** — at this date, re-run the audit. If still no weights, the next decision is whether to (a) hold further, (b) invoke the from-scratch training fallback (Risk #6 mitigation; 14 days on M5 Max), or (c) drop the SPANV2 swap from the 2026 Q2 refresh and reschedule for Q3.
4. **CVPRW 2026 poster session** (mid-June 2026) — typical release window for participant code drops. Worth a manual check during the conference week.
5. **C.4 throughput hypothesis becomes testable** — if the upstream PyTorch SPANV2 reference becomes runnable on Apple Silicon (via PyTorch MPS or an early MLX port), an early signal on the `mx.compile` fusion-recovery question may surface and could change the calculus even before weights drop.

## Non-revisit triggers (explicitly)

- A non-commercial license on SPANV2 weights does **not** force the from-scratch fallback. Per the plan §C.1, PDS / PKDSR are checked first, and if both are also non-permissive, *then* from-scratch is in play.
- Performance leadership shifts in NTIRE 2027 are not in scope; only this challenge cycle.

## References

- [Forge-CodingPlan-v1.0.md §C.1, §C.2–C.5, §5 Risk Register](../Forge-CodingPlan-v1.0.md)
- [Forge-Re-Evaluation-2026-05.md §2.3](../Forge-Re-Evaluation-2026-05.md)
- [ForgeUpscaler-PRD-v0.1.md §4.2, §7](../../ForgeUpscaler-PRD-v0.1.md)
- [Packages/ForgeUpscaler/LICENSES.md](../../Packages/ForgeUpscaler/LICENSES.md)
- arXiv:2604.03198 — "The Eleventh NTIRE 2026 Efficient Super-Resolution Challenge Report" (Bin Ren et al., 2026-04-03)
- [github.com/Amazingren/NTIRE2026_ESR](https://github.com/Amazingren/NTIRE2026_ESR) (umbrella repo, MIT, retrieved 2026-05-26)
