# ADR 0006 — Phase C Unfreeze: Adopt EfRLFN as Playback-Tier Candidate

**Date**: 2026-05-26
**Status**: Accepted
**Branch**: `feature/forge-2026-q2-refresh`
**Supersedes**: [ADR-0004](0004-spanv2-vs-fallback-ladder.md)
**Triggered by**: [Docs/Research/research-2026-05-26-three-surveys.md](../Research/research-2026-05-26-three-surveys.md) Survey 2

---

## Context

ADR-0004 (2026-05-26 AM) parked Phases C.2–C.5 until 2026-07-15 because no NTIRE 2026 ESR winner had published commercial-permissive weights. The external research survey delivered the same day found two things that change that assessment:

1. **SPANV2 is not the right unfreeze trigger.** XiaomiMM's NTIRE 2026 win came largely from a custom CUDA fused kernel (`span_attn_op`) that does not port to Metal. Even when permissive standalone weights drop, the speed advantage that motivated the swap may not transfer to Apple Silicon.

2. **A permissive non-NTIRE alternative exists today.** **EfRLFN** (arXiv 2602.11339, ICLR 2026, Bogatyrev et al. / Lomonosov MSU) ships under MIT with a pure-conv + ECA + tanh architecture that outperforms NVIDIA VSR, SPAN, and stock RLFN on user-preference-vs-runtime Pareto. Validated on **StreamSR**, a YouTube-derived UGC benchmark, by a crowd study with 3,800+ participants. Paper abstract cited ~300K params; **C.2 port verified ~504K params (~1.0 MB FP16)** at upstream default config (featureChannels=52, 6 ERLFB blocks, scale=4) — see "Verified at port" note below. No exotic ops — drops into MLX-Swift the same way the [B.1 NAFNet port](0003-nafnet-sizing-rescope.md) did.

Combined: the dependency that motivated the 2026-07-15 hold (waiting for a particular weight release) is the wrong dependency. The right dependency is a port + A/B that we can start now.

## Decision

**Lift the Phase C freeze. Adopt EfRLFN behind a feature flag in ForgeUpscaler's playback tier.** The 2026-07-15 calendar trigger is dropped.

### Ship criterion

EfRLFN ships to default if and only if **both**:

- **Quality**: VMAF ≥ +1.0 on a curated 100+ clip UGC short-form benchmark (genre-diverse) vs SRVGGNetCompact
- **Throughput**: Parity or better on M4 Pro at 1080p → 4K (≥30 fps target per plan §4 `playback_4k_fps_min`)

> **The throughput half is dropped per [ADR-0009](0009-drop-realtime-requirements.md)** — realtime is a separate-project concern. The C.4 verdict ([ADR-0008](0008-phase-c4-ab-verdict-srvggnet.md)) stood on **quality alone** (EfRLFN −26.8 VMAF), so the outcome is unchanged.

Revert trigger: VMAF gain < +0.5 or throughput regression > 20%.

### Fallback ladder if EfRLFN A/B underperforms

1. **SAFMN++** (MIT, AIS 2024 1st-place fidelity track on AVIF compressed images) — `sunny2109/SAFMN` upstream; ~150–240K params; ~0.6–1 MB FP16
2. **SPAN baseline** (Apache-2.0; NTIRE 2024 overall winner; CoreML port via ModelPiper proves Apple Silicon viability)
3. Hold SRVGGNetCompact (current baseline; BSD-3-Clause)

### What stays out of scope

- **SPANV2**: re-evaluate every 60 days. Trigger to revisit = (standalone HF model card under Apache-2.0 with weights) **AND** (CUDA `span_attn_op` removed or Metal/MLX equivalent available)
- **PDS / PKDSR**: weights still not published; no license; skip

## Outstanding concerns

### StreamSR data provenance — **CLEARED 2026-05-28** ✅

> **Update 2026-05-28**: MVS Collective legal cleared StreamSR for EfRLFN inference + fine-tuning, with the constraint that the StreamSR dataset itself does NOT get uploaded to repositories or release artifacts (the published MIT-licensed weights are fine; raw training data is not). This matches the existing corpus pattern (datasets are fetch-on-demand, never vendored). Captured in Task #19. Phase C.4 A/B and Phase C.5b ship are no longer gated on this review.

Original concern (kept for record): EfRLFN was trained on **StreamSR**, a 5,200-video YouTube-derived dataset. The model **weights** are MIT, but the **training data license** inherits from YouTube ToS. For inference-only use the model weights are sufficient; fine-tuning / retraining on MVS-owned content + StreamSR is now also permitted per the legal clearance.

### Inference path — published weights only, for now

Phase C.2 should load EfRLFN's released MIT-licensed checkpoint. No retraining on this branch. Fine-tuning paths unlocked by the 2026-05-28 clearance but not planned for this refresh's scope.

## Verified at port (2026-05-27, Task #18)

C.2 landed the MLX-Swift architecture port at `Packages/ForgeUpscaler/Sources/ForgeUpscaler/Playback/EfRLFN.swift`. Findings worth banking against the original research summary:

- **Param count: 503,894 trainable**, not the paper-abstract ~300K. Breakdown at upstream defaults: conv_1 = 1,456 · 6×ERLFB = 455,538 · conv_2 = 24,388 · upsampler.conv (scale=4) = 22,512. The agent preserved upstream defaults verbatim (per mlx-porting skill "transpose, not redesign") rather than chase the lower number. At FP16: ~1.0 MB on disk — still well under any bundle budget. Documentation correction, not a rescope trigger.
- **ECA uses fixed k_size=3**, NOT the standard `log2(C)/γ` formula from the ECA paper. Upstream `code/blocks.py:ECABlock` hardcodes it. Preserved for weight-load compatibility.
- **Dead kwargs dropped from Swift API**: `esa_channels`, `mid_channels`, `out_channels` on ERLFB are unused in upstream's forward path. Exposing them as knobs would mislead callers.
- **Global residual**: `conv_2` input is `out_b6 + conv_1_output` — easy to miss reading `model.py`; preserved exactly.
- **No internal downsampling**: odd-sized inputs flow through unchanged.
- **`numBlocks` precondition-locked to 6**: upstream weight keys use individual `block_1..block_6` names rather than a Sequential. Loosening requires a different C.3 converter key scheme.

These findings feed directly into the C.3 (Task #20) weight-conversion script — the converter must emit the `block_1..block_6` key scheme and handle the global residual correctly.

## Consequences

- Phase C.2 (architecture port) becomes the next ForgeUpscaler task; mirror of Task #10 (NAFNet B.1) shape
- Phase C.3 collapses from "weight conversion + numerical validation" to just "weight conversion from MIT-licensed published checkpoint" — much lighter
- Phase C.4 (decision gate) becomes the EfRLFN A/B per the ship criterion above
- Phase C.5 (integration) replaces SRVGGNetCompact in ForgeUpscaler's playback tier only if C.4 passes
- ADR-0004 status flips to Superseded
- The 60-day SPANV2 re-check stays as cron-scheduled task (Task #22)

## Revisit triggers

- **EfRLFN A/B fails the ship criterion** → fall to SAFMN++; new ADR documenting why
- **SPANV2 publishes permissive standalone weights AND removes the CUDA kernel dependency** → re-evaluate against whichever model the playback tier is currently on
- **A new NTIRE 2027 ESR challenge winner emerges with permissive weights + Metal-friendly architecture** → standard re-evaluation cycle

## References

- [Docs/Research/research-2026-05-26-three-surveys.md](../Research/research-2026-05-26-three-surveys.md) — Survey 2 § "Top 5 ranked fallback ladder" and § "Answer to the decision-critical question"
- EfRLFN paper: arXiv:2602.11339 (ICLR 2026)
- SAFMN++ upstream: `sunny2109/SAFMN`
- SPAN upstream: NTIRE 2024 challenge report (arXiv:2404.10343)
- Superseded ADR: [ADR-0004](0004-spanv2-vs-fallback-ladder.md)
