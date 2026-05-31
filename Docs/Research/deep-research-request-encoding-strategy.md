# Deep-Research Request — Encoding Strategy to Beat Vimeo on Signage

**Date**: 2026-05-31 · **Status**: ready for deep researcher (run when onsite, good internet)
**Requested by**: Forge Studio (MVS Collective) · **Owner**: Dustin

> Hand this whole doc to the deep-research harness. It is self-contained. Run the
> two PRIMARY questions first; SECONDARY two if budget allows. Deliverable: a
> cited report with concrete, Apple-Silicon-actionable recommendations.

---

## Context (what the researcher needs to know)

**Product**: Forge Studio is an on-device (Apple Silicon, MLX-Swift + CoreML),
non-realtime video **quality + compression** tool. Goal: take a source video and
produce an **optimally small file that retains the source's quality** — "Vimeo
parity" and better — for **digital signage** (motion graphics, display text, 3D
brand animation, sports footage, some real camera footage). Entry tier must run
on a **16 GB M1**.

**What we have shipping/validated** (don't re-derive):
- **AI super-resolution** (SRVGGNetCompact x4) — HD→4K on real signage at **+13
  VMAF over bicubic**; ~98.6 mean VMAF.
- **AI restoration** (NAFNet, trained on a noise/HEVC/AV1/MPEG-2 corpus, 2.54M
  params, fp16) wired as an encode pre-process.
- **Encoder**: we drive **x264 via ffmpeg at a CRF target** (constant quality).

**What we determined about Vimeo** (from analyzing their optimized files —
`Docs/Benchmarks/vimeo-method-analysis.md`): Vimeo ≈ **per-title, constant-quality
(CRF ~20) H.264 High@5.2**, adaptive B-frames, ~2–3 s GOP, **no super-resolution**.
Bitrate is content-adaptive (1.3–24 Mbps at 4K); VMAF is *not* targeted (ranges
81–98.5). So Vimeo is well-tuned per-title CRF — strong, but not the frontier.

**Our hypothesized edges over Vimeo**: (a) restoration before encode on degraded
input, (b) HD→4K SR, (c) a newer codec (AV1), (d) VMAF-targeted / per-shot rate
control. This research is to validate + quantify + prioritize those.

---

## PRIMARY Q1 — Content-adaptive encoding SOTA (the frontier beyond per-title CRF)

**Question**: What are the current best-practice and state-of-the-art methods for
content-adaptive video encoding that go *beyond* per-title CRF, and which are
practical to implement on-device (Apple Silicon, offline) for an entry tier?

Sub-questions:
- **Per-title vs per-shot vs per-scene** — Netflix's per-title (2015) and per-shot
  / **Dynamic Optimizer** / convex-hull bitrate-ladder optimization: how do they
  work, measured gains vs fixed CRF, and compute cost?
- **VMAF-targeted rate control** — practical ways to encode to a *target VMAF*
  (e.g. VMAF 93) rather than a CRF: ffmpeg/x264/x265/SVT-AV1 approaches, the
  `ab-av1`/`av1an` style CRF-search tools, two-pass + quality-search, and how to
  do it efficiently without N full encodes per clip.
- **Shot-boundary detection** prerequisites + cost on Apple Silicon.
- What's realistically achievable **offline on a 16 GB M1** vs what needs a farm.
- Quantified expected savings of each technique vs a flat CRF baseline.

What we already know: Vimeo ≈ flat-ish per-title CRF; we want the next rung up.

## PRIMARY Q2 — Pre-encode restoration/denoising → compression efficiency

**Question**: How much does denoising/restoration *before* encoding actually
improve compression efficiency (bits at equal perceptual quality), and what are
the best-practice methods + pitfalls?

Sub-questions:
- Literature/industry quantifying **bitrate savings from pre-encode denoising**
  (% at equal VMAF/SSIM), by content type (camera/grain vs clean motion-graphics).
- The **clean-content caveat**: on already-clean sources, does restoration help,
  hurt (adds detail/dither that costs bits), or wash out? (We measured ~neutral —
  +0.24 VMAF for ~2% size on clean signage. Is that consistent with the field?)
- **Grain/noise synthesis** (AV1 film-grain, x264 `--nr`, separate denoise+
  regrain) as the *opposite* lever — strip grain to compress, re-add at decode.
  Relevance for camera footage.
- Where a learned restorer (NAFNet-class) beats classical denoisers (NLMeans,
  BM3D, hqdn3d) for *compression* (not just quality).
- Failure modes: restoration removing real detail → worse rate-distortion.

What we already know: NAFNet trained + wired; its compression value should be on
*degraded* input. We want the quantified picture + best practice.

## SECONDARY Q3 — Vimeo's published pipeline + roadmap

Confirm/refute our reverse-engineering: Vimeo's public statements (engineering
blog, conference talks, docs) on their transcode pipeline — per-title CRF? preset?
**AV1 adoption/roadmap?** Any per-shot/convex-hull? Resolution-ladder logic. Cite
primary sources.

## SECONDARY Q4 — AV1 (SVT-AV1) on Apple Silicon for this content

Is an AV1 codec leap worth it for Forge's entry tier? Sub-questions: SVT-AV1
encode efficiency vs x264/x265 at equal VMAF on signage-like content (% bitrate
saved); **encode speed on Apple Silicon (M-series, offline)** at usable presets;
hardware AV1 *decode* availability on target playback devices (signage players,
Apple TV, M-series); film-grain synthesis; libaom vs SVT-AV1 vs rav1e tradeoffs;
container/HLS/fMP4 implications.

---

## Deliverable

A cited report (primary sources preferred — papers, engineering blogs, codec
docs, benchmarks) that for each question gives: the answer, the **quantified
gain**, the **on-Apple-Silicon-offline feasibility**, and a **concrete
recommendation** for Forge's entry (16 GB M1) and high-end tiers. End with a
prioritized "what should Forge implement next, in order" list across Q1–Q4.

## Constraints to honor in recommendations

- On-device, Apple Silicon (MLX-Swift / CoreML / VideoToolbox / ffmpeg-libx264).
- Entry tier = 16 GB M1 floor; non-realtime is acceptable (ADR-0009).
- We can ship x264 today; AV1 is a candidate, not committed.
- Licensing matters (LGPL ffmpeg split already in place; flag any GPL/patent
  encumbrance, e.g. x264 GPL vs our LGPL runtime split).
