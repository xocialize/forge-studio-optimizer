# Vimeo Encoding-Method Analysis (postulated)

**Date**: 2026-05-31
**Method**: `ffprobe` + CRF-sweep re-encode on the local IBM↔Vimeo pairs
(`~/DEV_INT/IBM_Pairs/`, off-repo). Outputs analyzed: the Vimeo 1080p/2160p
optimized files vs the IBM source masters. This note (aggregate findings) is
committed; the clips are not.

## TL;DR

Vimeo's optimization is **per-title, constant-quality (CRF-style) H.264** —
**not** a fixed-bitrate ladder and **not** VMAF-targeted. Operating point ≈
**x264 ~CRF 20**, lightly per-title (complex/motion content gets extra quality),
streaming-oriented GOP. **No super-resolution** — their 4K outputs encode the
native-4K source; 1080p is a downscale.

## Evidence

### 1. Bitrate is content-adaptive (18× spread at the same resolution)

Vimeo 2160p outputs, all H.264 **High@5.2**, same 4K-class resolution:

| clip | content | Vimeo 2160p Mbps |
|---|---|---|
| smarter | flat text | **1.3** |
| characters | illustration | 3.9 |
| sevilla | people/sports | 4.0 |
| abacus | 3D | 5.5 |
| layersb | gradient | 7.2 |
| ferrari | high motion | 10.9 |
| img3140 | 4K camera (real texture) | **24.2** |

A fixed-bitrate ladder would hold bitrate constant per rung; this varies 18× with
complexity ⇒ content-adaptive.

### 2. Quality is constant-*quantizer*, not constant-VMAF

Cross-referencing bitrate with our measured col-A VMAF (Vimeo-2160p vs source):

| clip | Mbps | VMAF |
|---|---|---|
| smarter | 1.3 | 98.5 |
| img3140 | 24.2 | **81.4** |
| ferrari | 10.9 | 84.8 |
| abacus | 5.5 | 97.0 |

VMAF ranges **81→98.5** and is *inversely* related to bitrate at the hard end
(img3140 = highest bitrate **and** lowest VMAF). A VMAF-targeted encoder would
flatten VMAF; this is the signature of a **constant quality factor (CRF/CQP)** —
hard content gets more bits but still lower VMAF because it's intrinsically hard
(+ real-camera source noise VMAF penalizes).

### 3. CRF-match: re-encoding the sources locates Vimeo's operating point

Source re-encoded at a CRF sweep (libx264 `medium`, native res, 15 s):

| clip | Vimeo Mbps | CRF 19 | CRF 21 | CRF 23 | ≈ Vimeo CRF |
|---|---|---|---|---|---|
| smarter | 1.3 | 1.5 | 1.2 | 1.0 | **~20–21** |
| img3140 | 24.2 | 35.0 | 23.3 | 15.7 | **~21** |
| ferrari | 10.9 | 9.5 | 7.2 | 5.3 | **~18** |

Two of three land at **CRF ~20–21**; ferrari (motion) got *more* bits than a flat
CRF 21 → evidence of **per-title tuning** (extra quality for complex content),
not a single fixed CRF. (Caveat: Vimeo's preset is unknown — a slower preset
shifts the CRF↔bitrate mapping; the *operating point* is the robust read, not the
exact CRF integer.)

### 4. Encoder fingerprint

H.264 **High@5.2**, `yuv420p`, **bt709** (primaries/transfer/matrix),
progressive, **adaptive B-frames** (`has_b_frames=2`; static text → long P-runs,
motion → dense B-frames), **~2–3 s keyframe interval** (~3 I-frames/8 s —
HLS/streaming-oriented, plus scene-cut keyframes).

## Implications for Forge

1. **Match Vimeo — we already have the tool.** Forge's `--crf` compression path
   (ADR-0012) *is* x264 CRF. Dial it to **~CRF 20–21** (we used 23) and Forge
   lands on Vimeo's operating point; on clean signage we're at parity by
   construction (same codec, same rate control).
2. **Beat Vimeo — three edges they don't have:**
   - **NAFNet restoration before encode** — on *degraded* input, denoising strips
     high-entropy noise the encoder would spend bits on (the #38 UGC home-turf
     case). Quantify via the "restoration→compression" research below.
   - **HD→4K SR** — Vimeo *cannot* make HD look native-4K (no SR; measured +13
     VMAF for Forge). A category they don't offer.
   - **AV1 (SVT-AV1)** — they're on H.264; AV1 is a ~30–50% bitrate edge at equal
     quality. Codec-leap differentiator.
3. **Reach beyond parity — VMAF-targeted / per-shot encoding.** Vimeo stops at
   per-title CRF; the SOTA frontier (Netflix per-shot / convex-hull / Dynamic
   Optimizer) targets a *quality* not a quantizer. See the research request.

## Caveats

- Single show's content (IBM Think 26); only H.264 observed (Vimeo may serve AV1
  elsewhere). Vimeo's exact preset + per-title algorithm are inferred, not known.
- "CRF ~20" is the operating *point*; the exact integer depends on their preset.

## Next experiments (no internet)

- Re-run Forge `--crf 20` on a clip and compare (bitrate, VMAF) head-to-head vs
  the matching Vimeo file → confirms parity at their operating point.
- On a *degraded* clip: Forge (NAFNet + CRF) vs plain CRF at equal VMAF → sizes
  the NAFNet compression edge directly.
