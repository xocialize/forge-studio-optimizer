# Forge Studio Encoding Strategy — Deep-Research Report (Q1–Q4)

*v2 — encoder ladder revised for an Apple-first client base (iPhone 8 floor). Launch encoder is Apple VideoToolbox (HEVC default / H.264 fallback); licensed-x264 demoted to a conditional quality-premium path; AV1 remains an opt-in, build-selected tier for AV1-decode-capable targets.*

**Bottom line up front:** Forge's biggest *near-term* wins are not a codec change — they come from layering **VMAF-targeted, per-shot capped-CRF-style rate control** on top of the encoder, which the literature puts at roughly **20–40% additional bitrate savings over a flat CRF baseline at equal perceptual quality**, all feasible offline on the 16 GB M1 floor. For an **Apple-first client base (iPhone 8 floor → Apple TV → M-series)**, the recommended **launch encoder is Apple's VideoToolbox** — HEVC as the efficient Apple-native default, H.264 as the universal fallback — which is **$0 in codec licensing, hardware-accelerated on the dedicated media engine of every Apple chip (constant cost across the sliding scale), and avoids the x264 GPL/patent question entirely**. Licensed-x264 is demoted to a *conditional quality-premium path* only if A/B testing proves the quality-per-bit gap justifies the spend. AV1 (SVT-AV1) is a real but *conditional* leap (~40–50% over x264 at equal VMAF) gated almost entirely by **playback-device decode support** — your iPhone 8 floor cannot decode it (needs A17 Pro / iPhone 15 Pro+) — so it belongs in the mid/high tiers as an opt-in, build-selected export for AV1-capable targets.

## TL;DR

- **Launch on VideoToolbox, served per-player.** With an Apple-first base and build-selection-by-player already in your plan, ship **VideoToolbox HEVC** as the efficient default (decodes in hardware on everything from the iPhone 8 floor up), **VideoToolbox H.264** as the universal-compatibility fallback, and **AV1** only to AV1-capable endpoints. This is license-clean ($0 codec licensing), hardware-accelerated at constant cost across every Apple chip tier, and removes the ffmpeg+x264 dependency from the shipped binary.
- **Content-adaptive rate control is the highest-ROI next step and runs on the floor tier.** Move from a single global quality target to **per-shot, VMAF-targeted** encoding: detect shots (PySceneDetect/ffmpeg, cheap/CPU), search each shot against a VMAF target (ab-av1 "sample-encode" style — a few short probe encodes instead of N full encodes), and stitch. Expect **~20% (per-title) up to ~30–40% (per-shot) bitrate reduction at equal VMAF** versus a fixed quality setting, on top of your existing NAFNet + SR edges. This beats Vimeo's per-title CRF on its own terms. Note: VideoToolbox's quality knob is *coarser* than x264 CRF, so you capture much — not all — of the per-shot upside unless you add a licensed-x264 premium path.
- **Pre-encode restoration helps mainly on *degraded/grainy* input, and is correctly ~neutral on clean signage.** Your measured **+0.24 VMAF for ~2% size on clean motion-graphics is exactly what the field predicts**. Large wins (10–20% at equal VMAF; up to ~50% on heavy grain) require a noisy/film-grain source; the right lever for camera footage is **denoise-then-regrain (film-grain synthesis), not detail-removing restoration**.
- **AV1 is worth it only where the *player* decodes it — and your iPhone 8 floor can't.** SVT-AV1 saves ~40–50% vs x264 at equal VMAF and is BSD/royalty-free, but AV1 hardware decode on Apple clients begins at A17 Pro (iPhone 15 Pro+) / M3. Ship AV1 as a build-selected export tier for capable targets; HEVC/H.264 stay the universal defaults.

## Key Findings

1. **Per-title → per-shot is a measured, stackable gain.** Netflix per-title (2015) averaged ~20% at constant quality; the per-shot Dynamic Optimizer (2018) adds materially more (Netflix production: 17% vs AVCHi-Mobile, 30% vs VP9-Mobile at VMAF=80; Mux summarizes the consensus as ~20% per-title / ~30% per-scene). These gains are rate-control wins and are **largely encoder-agnostic** — they apply whether the final encoder is VideoToolbox, x264, or SVT-AV1.
2. **You do not need N full encodes per clip.** "Sample-encode" quality search (ab-av1) predicts VMAF/size from a few short probes — ab-av1's author measured "19 seconds vs ~13 minutes" for a full encode — making VMAF-targeting practical even on the M1 floor.
3. **Restoration is a rate-distortion lever, not a universal quality button.** A learned restorer (NAFNet-class) beats classical denoisers (hqdn3d/NLMeans/BM3D) for *compression* when input is genuinely degraded; on clean input it should be bypassed.
4. **Vimeo's published record confirms your reverse-engineering:** per-title H.264 (x264/x265), VMAF *measured inline, not targeted*, AV1 only on a tiny Staff-Picks subset via **rav1e** (not SVT-AV1), no public per-shot/convex-hull.
5. **Licensing strongly favors the VideoToolbox-first plan:** Apple's OS encoder is licensed at the platform level, so Forge incurs **no x264 GPL obligation and no encoder-side H.264/HEVC patent royalty**. Licensed-x264 would add a negotiated software fee (historically ~$1/unit, 10k-unit min → low five figures/yr) plus a Via LA H.264 patent obligation ($0 under 100k units/yr; the headline $4.5M streaming hikes do **not** apply to a file-producing tool). SVT-AV1 (BSD-3-Clear + AOM Patent License 1.0) is royalty-free. `libvmaf` (Apache-2.0) forces any in-process FFmpeg build to LGPL **v3**.

---

## Q1 — Content-Adaptive Encoding: The Frontier Beyond Per-Title CRF

### What the frontier actually is

Per-title CRF (what Vimeo does) tunes **one operating point per asset**. The frontier beyond it is a hierarchy:

- **Per-title / per-asset** (Netflix 2015): one analysis pass builds a convex hull of (resolution, bitrate, VMAF) points across the whole title; pick the operating point that hugs the hull. Reported gains: **~20% at constant quality, up to ~40% vs a fixed ladder** (Netflix; corroborated by Bitmovin 22.7%–87% top-rung savings by content). For a single-output tool like Forge, the equivalent is "pick the optimal quality (and resolution) for *this* clip."
- **Per-shot / per-scene** (Netflix Dynamic Optimizer, 2018): split into shots, build a convex hull *per shot*, stitch optimal per-shot points along a constant-slope trellis. Current SOTA for VOD. Measured: Dynamic Optimizer reports 17.1–22.5% (PSNR) and "over 50% … in terms of HVMAF" vs a 2-pass VBR baseline (explicitly a lower bound at constant complexity). Production follow-up: 17% vs AVCHi-Mobile, 30% vs VP9-Mobile. Streaming Media reports cross-codec Dynamic Optimizer gains over a fixed ladder as 28.0% (x264) / 37.6% (VP9) / 33.5% (x265).
- **VMAF-targeted / constant-quality** (Constant Target Quality, capped CRF): encode to hit a *target VMAF* (e.g., 93–95) per shot, capping bitrate where the encoder overshoots. NETINT: ~16% at CRF 23; ~43% at VMAF ~95 / CRF 27. Academic per-scene variants (JASLA, ViSOR) report 34–43% (VMAF) savings vs an x265 HLS CBR ladder.

**Net for Forge:** moving from a single global quality target to **per-shot VMAF-targeted** encoding is the single highest-ROI change — **~20% (whole-clip-as-one-title) to ~30–40% (true per-shot) at equal VMAF** — stacking on top of NAFNet/SR, and out-positioning Vimeo's per-*title*-only pipeline.

**Encoder-knob caveat (new in v2):** these gains assume reasonably fine-grained rate control. **VideoToolbox exposes a coarser constant-quality knob than x264 CRF** and lacks x264's clean-content micro-levers (`--tune animation`, DCT-decimation off, psy-rd, fine B-frame/ref tuning). You can still run a VMAF-targeted sample search over VideoToolbox's quality parameter — you'll realize **most but not all** of the per-shot upside. Closing the remaining gap is the main argument for a licensed-x264 premium path (Step 5).

### (b) How to target VMAF without N full encodes

The naive approach (encode at many settings, full-VMAF each) is what makes per-shot "need a farm." The practical on-device method is **sample-encode quality search** (ab-av1: Rust CLI wrapping ffmpeg + encoder + libvmaf; supports x264/x265/SVT-AV1): cut short representative samples, encode only those at a candidate setting, VMAF the samples, predict full-clip VMAF/size, then interpolated-binary-search the quality parameter to hit `--min-vmaf` within a size cap. For per-shot work, **av1an** (rust-av/Av1an) is the off-the-shelf framework — scene-detection-based chunked encoding, Target Quality mode, parallel chunks, runs on macOS, wraps SVT-AV1/x264/x265/aom/rav1e — ideal for prototyping the per-shot pipeline before native FormatBridge reimplementation. **For VideoToolbox**, you'll wrap the same search logic around VideoToolbox's quality knob rather than CRF.

### (c) Shot-boundary detection cost on Apple Silicon

Cheap and not the bottleneck. **PySceneDetect** (BSD-3) `detect-content`/`detect-adaptive` on a 2× downscaled luma copy runs many times faster than real time; FFmpeg `select='gt(scene,...)'` is faster still. ML CNN detectors hit >100× real-time on one GPU. **Recommendation:** FFmpeg scene-score or PySceneDetect content-mode on downscaled luma — trivial on the M1 floor.

### (d)/(e) Sliding-scale feasibility and expected savings

| Technique | Saving vs flat CRF (equal VMAF) | 16 GB M1 floor | Mid-tier (M-Pro/Max) | High-end (M5 Max) |
|---|---|---|---|---|
| **Optimal single quality via sample-search** | ~10–20% | ✅ Easy | ✅ | ✅ |
| **Per-shot VMAF-targeted, capped** | ~20–40% | ✅ Offline (serial shots) | ✅ Parallel chunks | ✅ Many parallel chunks |
| **Convex-hull incl. multiple resolutions/shot** | adds a few % + right-sizes resolution | ⚠️ Limit resolution candidates | ✅ | ✅ Full hull search |
| **Shot detection (PySceneDetect/ffmpeg)** | enabler | ✅ Trivial on downscaled luma | ✅ | ✅ |

Floor-tier guidance: cap concurrency (1–2 shots in flight), keep VMAF probes short, process serially overnight (ADR-0009). The convex-hull-over-resolutions variant is where compute genuinely scales with hardware; on the floor, restrict the resolution candidate set (source + one downscale).

---

## Q2 — Pre-Encode Restoration / Denoising and Compression Efficiency

### (a) How much does pre-encode denoising actually save?

Random noise/grain is high-entropy and incompressible. Content-dependent results:

- **Camera/grain content:** ~10–20% additional bitrate savings at equal VMAF from a temporal denoise pass.
- **Heavy film grain (strip + re-synthesize):** up to ~50% on grainy sources; Netflix *AV1 @ Scale: Film Grain Synthesis* (July 2025) reports ~66% on a heavy-grain title (8274→2804 kbps) and a 36% average reduction across ~300 grainy titles at 1080p+.
- **Old/degraded film:** denoising lets the codec hit acceptable quality at a fraction of the bitrate (e.g., 15 Mbit → ~5.4 Mbit with NLMeans on grainy film).

### (b) The clean-content caveat — your ~neutral result is correct

On clean sources (motion graphics, display text, 3D brand animation), restoration has little noise to remove and can *hurt*. **Your +0.24 VMAF for ~2% size is squarely consistent with the field.** SVT-AV1 docs warn the FGS denoise stage can delete fine detail and recommend film-grain=0 for animation/CGI; x264 guidance says turn DCT-decimation off for clean CG and use `--tune animation`, not denoising; the learned-compression literature (arXiv:2307.06233) finds denoising's benefit *scales with input noise* and is near-neutral on clean input. **Implication:** gate NAFNet by an input-degradation/IQA signal (your SigLIP2 NR-IQA head) — run on degraded input, bypass on clean motion-graphics.

### (c) Grain/noise synthesis — the opposite lever for camera footage

Decouple grain from signal: denoise, encode the clean signal cheaply, re-add grain at decode. **AV1 film-grain synthesis (FGS)** stores only an autoregressive grain model as metadata; SVT-AV1 `--film-grain` (8–15 live action, 0 animation) delivers the up-to-50%/66% savings. Caveat: synthesized grain lowers VMAF/PSNR vs the reference, so tune on the *denoised* signal or disable grain for metric calc. **H.264 has no in-codec FGS** — and VideoToolbox does not expose it; for the camera-footage slice this is an argument for an AV1 export where the target decodes it. **HEVC FGS exists in the spec but is not exposed by VideoToolbox.**

### (d) Where NAFNet beats classical denoisers for *compression*

NAFNet wins when it removes incompressible artifacts *while preserving real structure*, and yours is trained on the right corpus (noise/HEVC/AV1/MPEG-2 artifacts on domain signage frames) — artifact-aware, not just noise-aware. hqdn3d is fast but degrades the whole image; NLMeans preserves detail but is very slow (<0.1 fps at 4K). **NAFNet remains the better front-end for previously-compressed/degraded input; FGS (AV1) is the better tool for fresh camera grain.**

### (e) Failure modes

Dominant failure mode: **over-denoising** removes real high-frequency detail (text edges, fast particles), *raising* downstream rate-distortion cost. The repo's fp16 global-pool overflow (garbage at 4K, VMAF 3.17, invisible at tile resolution) is a related hazard. **Mitigations:** keep NAFNet gated to degraded input; validate at production resolution; auto-bypass the restorer if it moves VMAF *down*.

### Sliding-scale feasibility (Q2)

| Lever | Floor (16 GB M1) | Mid-tier | High-end (M5 Max) |
|---|---|---|---|
| **NAFNet restoration (2.54M, fp16) on degraded input** | ✅ With 4K tiling; slow but offline-OK | ✅ Larger tiles | ✅ Whole-frame, batched |
| **hqdn3d pre-filter (fast classical)** | ✅ Real-time-ish | ✅ | ✅ |
| **NLMeans pre-filter (HQ, slow)** | ⚠️ <0.1 fps at 4K — overnight only | ⚠️ Still slow | ✅ Tolerable |
| **AV1 film-grain synthesis (denoise+regrain)** | ✅ (cost is the AV1 encode) | ✅ | ✅ |
| **IQA-gated restore decision (SigLIP2)** | ✅ Cheap inference | ✅ | ✅ |

---

## Q3 — Vimeo's Published Pipeline (Confirm/Refute)

Vimeo's public engineering record **confirms the team's reverse-engineering**:

- **Per-title, quality-first H.264 backbone.** *VMAF FTW* (Thomas Daede): decode → scale → tonemap → encode into multiple resolution/setting profiles; x264/x265 confirmed in the path. Vimeo's highest-bitrate encodes run notably higher than YouTube — consistent with quality-first per-title and your 1.3–24 Mbps@4K range.
- **VMAF is measured inline, not targeted** — computed during encode for analytics, not as a closed-loop per-shot rate-control target. Matches your 81–98.5 output range. **This is the gap Forge exploits.**
- **AV1 is real but narrow, and uses rav1e — not SVT-AV1.** Launched 2019 only for Staff Picks; built the open-source Elevator tool to fix AV1 level signaling for decoder compatibility. Held back by dual-catalog storage cost.
- **No public per-shot / convex-hull / Dynamic Optimizer.** Per-title ladder with resolution rungs + an upscaled-upload data-quality check. Newer Falkor infra is about scale/cost, not a per-shot algorithm.

**Verdict:** Vimeo = well-tuned per-title constant-quality H.264, rav1e AV1 on a tiny subset, VMAF as measurement not target. Forge's edges — restoration on degraded input, HD→4K SR, AV1, and especially **VMAF-targeted per-shot rate control** — are all genuinely beyond what Vimeo publishes.

---

## Q4 — AV1 (SVT-AV1) on Apple Silicon, and Codec Decode Support

### Is the AV1 leap worth it for Forge's tiers?

**Conditionally yes — as a build-selected export tier, gated on playback decode support, not on your encode hardware.**

**Efficiency vs x264/x265 at equal VMAF.** SVT-AV1 saves ~40–50% vs x264 (Facebook ~50%; VMAF BD-rate ~41.5%; ~48% lower average bitrate than H.264 in independent stream analysis; up to 62–72% BD-rate at 4K vs a slow x264 baseline). Vs x265: comparable-to-modestly-better at higher speed. For **clean signage motion graphics** near the VMAF ceiling, expect the **lower** end of the AV1-vs-x264 range, but still material at Forge's target bitrates.

**Encode speed on Apple Silicon (software only).** No hardware AV1 *encode* on any Apple chip below the M5 Pro/Max (~Mar 2026); M3/M4 added only AV1 hardware *decode*. SVT-AV1 reference (HandBrake, full ~79-min movie, default preset): M1 Max ~21 min, M2 Max ~17.5 min, M3 Max ~12.8 min (≈6× real-time). SVT-AV1 3.0 added Arm NEON/SVE2 gains. Guidance: preset 4–6 for quality VOD, 8 for "fast enough"; the 16 GB M1 can encode AV1 offline but is slowest/RAM-constrained at 4K — keep it to preset 6–8 / lower resolutions, or treat AV1 as mid/high-tier.

**`libaom` vs SVT-AV1 vs rav1e:** **SVT-AV1** is the right choice (speed/quality/threading, actively Arm-optimized). libaom = reference, glacial. rav1e = what Vimeo uses, generally slower/less efficient than current SVT-AV1.

### Codec decode support on target playback devices — the real gate

| Target | H.264 | HEVC (Main, 8-bit) | AV1 |
|---|---|---|---|
| **iPhone 8 (A11) — your client floor** | ✅ | ✅ hardware | ❌ (needs A17 Pro / iPhone 15 Pro+) |
| iPhone 15 Pro+ / recent iPad | ✅ | ✅ | ✅ (A17 Pro / M3+) |
| Apple TV | ✅ | ✅ | ❌ until A17/M3-class silicon |
| M-series Macs | ✅ | ✅ | ✅ M3 and later only |
| Non-Apple signage players (BrightSign etc.) | ✅ | mostly ✅ (Series-4/HD2xx) | only newest Series-5 |

**Key consequence for an Apple-first base:** even your **iPhone 8 floor decodes HEVC in hardware**, so HEVC is a safe efficient default across the entire Apple client range. **AV1 is the only codec your floor cannot do** — confirming it as an opt-in, build-selected tier for A17 Pro / M3+ endpoints. Your stated ability to host multiple versions and select the build by player is exactly the right mechanism: serve AV1 to capable players, HEVC to the Apple mainstream, H.264 as the universal floor.

**Container/HLS/fMP4:** HEVC and AV1 both ship in fMP4/CMAF/HLS; AVPlayer decodes both on supported hardware. For AV1, set the **level** correctly (Elevator-style) or low-power decoders stutter. Maintaining multiple codecs means multiple renditions — but you're already planning per-player builds, so this is a packaging step, not new architecture.

### Licensing posture (revised recommendation)

- **VideoToolbox H.264/HEVC (recommended launch encoder).** Using Apple's OS-level encoder means **Forge incurs no x264 GPL obligation and no encoder-side H.264/HEVC patent royalty** — Apple holds the platform codec licenses. It runs on the **dedicated hardware media-encode block**, so encode cost is roughly **constant across chip tiers** (the M1 floor encodes fast/cool where x264 `slow`/`veryslow` software encoding struggles most), and it removes the ffmpeg+x264 dependency from the shipped binary (simpler notarization, smaller app). Cost: a **coarser rate-control knob** and the loss of x264's clean-content micro-levers, i.e. somewhat lower quality-per-bit than x264 `slow`/`--tune` at a given target. **For an Apple-first launch this is the right default.**
  - *Content-side caveat:* the encoder-side obligation vanishing is solid (you're calling Apple's licensed OS encoder, not manufacturing/distributing a codec). Patent questions on *distributed content* exist regardless of which encoder produced the file and sit with the signage operator, not the tool — and HEVC's content-side landscape involves multiple pools (Via LA / Access Advance / Avanci), so don't overstate "HEVC is totally clean" to clients.
- **Licensed x264 (conditional quality-premium path).** x264 is GPL; your repo ships an LGPL FFmpeg build excluding it (ADR-0002). To ship x264 in a proprietary app: GPL the app **or** buy a commercial x264 license (negotiable; historically ~$1/unit, 10k-unit minimum → low five figures/yr) **plus** a Via LA H.264 patent license. Realistic patent exposure for a file-producing tool is **$0 (under 100k units/yr)**; the recent $4.5M streaming-fee hikes apply to OTT/streaming *services*, not to Forge. **Adopt only if A/B testing on your corpus shows the quality-per-bit gain over VideoToolbox justifies the spend and the GPL/patent overhead.**
- **SVT-AV1 / AV1.** BSD-3-Clause-Clear + AOM Patent License 1.0 — royalty-free, no copyleft. The AOM patent license is a royalty-free cross-license (benign unless MVS holds codec patents). **Materially de-risks licensing** vs the x264+Via LA stack.
- **libvmaf:** Apache-2.0 — incompatible with LGPL v2.1 but compatible with v3, so any in-process FFmpeg+libvmaf build must use `--enable-version3` (LGPL v3). Calling VMAF as a separate binary avoids entangling it with the runtime split.

---

## Recommendations — What Forge Should Implement Next, In Order

Ordered by **ROI ÷ implementation cost**. "Floor" = 16 GB M1 (encode) / iPhone 8 (playback); "Mid" = M-Pro/Max; "High" = M5-class.

**0. (Q4/Licensing) Make VideoToolbox the v1 launch encoder, served per-player — DO FIRST. [All tiers; constant cost.]**
Ship **VideoToolbox HEVC** as the efficient Apple-native default (hardware decode from the iPhone 8 floor up), **VideoToolbox H.264** as the universal fallback, and wire your build-selection-by-player so AV1 can slot in later for capable endpoints. License-clean ($0 codec licensing), hardware-accelerated at constant cost across chip tiers, no ffmpeg/x264 dependency in the binary. This is the launch-direction decision everything else hangs off.

**1. (Q1) VMAF-targeted quality search ("auto-quality") via sample-encode. [Floor →]**
Replace a fixed quality setting with a per-clip target chosen by a short sample-encode search against a VMAF target (start VMAF 95 for "Vimeo-parity-and-better," 93 for "smaller"), wrapped around the **VideoToolbox quality knob**. Reuse ab-av1's binary-search-on-probes algorithm natively in FormatBridge. **Gain: ~10–20% at equal VMAF, ships on the floor, minimal code.** Advance threshold: median size reduction ≥10% vs fixed setting at equal-or-better VMAF on your 30-clip corpus.

**2. (Q1) Per-shot VMAF-targeted, capped (shot detect → per-shot target → stitch). [Floor serial; Mid/High parallel.]**
Add FFmpeg/PySceneDetect shot detection (downscaled luma) and run the auto-quality search per shot with a per-shot cap, then concatenate. Prototype with **av1an** to validate gains before native reimplementation. **Gain: ~20–40% at equal VMAF — the biggest single win and a clean differentiator over Vimeo.** Threshold: ≥20% additional savings vs step 1 on multi-shot clips; single-shot signage loops fall back to step 1. (Realize *most* of this on VideoToolbox's coarser knob; full upside needs Step 5.)

**3. (Q2) IQA-gated NAFNet restoration. [Floor with 4K tiling; Mid/High whole-frame.]**
Wire SigLIP2 NR-IQA as the gate: run NAFNet only on degraded/previously-compressed input; bypass on clean motion-graphics (your +0.24 VMAF / +2% size proves it's ~neutral). Auto-bypass if restoration drives VMAF down. **Gain: 10–20% at equal VMAF on degraded input; ~0 on clean — gating is the value.** Mostly glue code on shipped models.

**4. (Q4) AV1 (SVT-AV1) opt-in export tier with film-grain synthesis. [Mid/High encode; A17 Pro / M3+ playback.]**
Add SVT-AV1 as a build-selected target (preset 4–6 quality, 8 for speed; `--film-grain 8–15` for camera footage, 0 for graphics), gated on declared playback AV1 decode. Keep HEVC/H.264 the defaults. Set AV1 level correctly (Elevator-style). **Gain: ~40–50% vs x264 at equal VMAF where the player decodes AV1** — your iPhone 8 floor does not, so this is strictly an upgrade lane for newer endpoints.

**5. (Q1/Licensing) Licensed-x264 quality-premium path — only if justified. [Mid/High primarily.]**
If A/B testing shows VideoToolbox's coarser rate control leaves meaningful quality-per-bit on the table at your VMAF targets, add a licensed-x264 path (commercial x264 + Via LA H.264) to capture x264's CRF granularity and clean-content tunes (`--tune animation`, DCT-decimation off, psy-rd). **Decision-gated, not assumed** — the whole point of Step 0 is to launch without this.

**6. (Q1) Convex-hull-over-resolutions per shot (joint resolution + quality right-sizing). [High-end primarily.]**
Full Netflix-style hull (multiple resolutions per shot). Adds a few % and prevents over-spending bits on a resolution the content doesn't support. Compute-heavy — reserve for the 128 GB tier or overnight jobs; restrict the resolution candidate set on lower tiers.

### Caveats and confidence

- **Quantified savings are content-dependent** (figures from streaming/VOD studies). Per-shot/VMAF-target gains will be largest on mixed/sports footage, smallest on already-clean near-lossless graphics. Validate every number on your own 30-clip corpus before quoting it.
- **VideoToolbox quality gap is real but bounded.** Modern VideoToolbox HEVC is far better than its early reputation, but it still won't match x264 `veryslow` on the hardest clips. The Step-5 gate exists precisely to measure this rather than assume it.
- **AV1-vs-x264 "40–50%" spans a wide band** (~41% to ~72% by baseline/resolution/metric); expect the lower end at near-lossless. Test AV1 on text and 3D edges specifically (`--enable-tf 0` to mitigate temporal-filtering scene-change issues).
- **Hardware/version facts to re-verify at ship time:** M5 Pro/Max AV1 hardware encode, SVT-AV1 versions, and per-device decode support are current as of mid-2026 — confirm against Apple's media-engine specs and the specific deployed fleet before enabling AV1 output. iPhone 8 HEVC hardware decode (A11) is well-established; confirm any 10-bit/HDR assumptions if you go beyond 8-bit Main.
- **VMAF is not the whole story.** Spot-check heavy-display-text content with SSIMULACRA2/XPSNR and human review; treat VMAF targets as a floor, consistent with your multi-gate harness.
- **Not legal advice.** For GPL-distribution and patent-scope specifics (especially HEVC content-side pools), get a short consult with IP counsel since MVS ships commercially.
