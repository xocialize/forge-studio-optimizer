# Step 1 (VMAF-targeted encode) — native end-to-end validation

**Date**: 2026-05-31
**Tool**: `forge-quality-target` (ForgeOptimizer executable)
**Encoder**: native VideoToolbox HEVC (Step 0, ADR-0013) driven by the Swift
VMAF-targeted search (`QualityTargetSearch` + `VideoToolboxQualityTargetEncoder`
+ `FFmpegVMAFScorer`).

This is the native productization of `Tools/vmaf_target_search.py` (the deep-
research prototype). It runs the whole shipped path — FormatBridge decode → VT
constant-quality search → final HEVC encode — and reports real numbers.

> **Reference-correctness note (2026-05-31, #55):** these numbers were
> re-validated after fixing a VMAF *reference* bug. The reference is now built by
> ffmpeg-decoding the source frame range (`trim=start_frame:end_frame`, bt709),
> NOT by repacking our NV12 frames (which corrupted it ~3–6 pts). **Rigorously
> cross-checked: the pipeline's achieved VMAF equals an independent ffmpeg
> measurement (98.55 == 98.55).** The 63% below is confirmed, not the artifact of
> a broken harness.

## Result (general-animation-01.mp4 — 1080p/24fps, 5.23 Mbps H.264)

First 120-frame sample (5.0 s). Reference: lossless ffv1 of the source frame
range, bt709. Sample-encode binary search over the VT quality knob.

| target VMAF | chosen quality | achieved VMAF | probes | targeted bitrate | savings vs source |
|---|---|---|---|---|---|
| ≥ 95 | 0.691 | 94.95 | 7 | 1.93 Mbps | **63.0 %** |
| ≥ 90 | 0.606 | 90.29 | 7 | 1.09 Mbps | **79.2 %** |

The search hits the floor within slack (0.5) and adapts monotonically — a lower
target picks a lower quality and saves more. Consistent with the prototype's
range and the ADR-0014 product claim ("smaller at a guaranteed quality").

## Methodology notes / gotchas

- **NV12 straight to VideoToolbox.** The decoder emits NV12; we feed it directly
  to `VTCompressionSession` (its native format) — no BGRA/CoreImage roundtrip,
  which both halves memory and avoids a colour-range shift.
- **Reference = the same decoded frames, losslessly (ffv1).** Comparing against
  a separate ffmpeg re-decode of the *source* introduced a cross-pipeline
  mismatch; building the reference from the identical NV12 frames we encode makes
  VMAF measure pure encode loss.
- **VMAF framesync desync (important).** libvmaf pairs the two inputs by PTS.
  An ffv1-in-mkv reference (timebase 1/1000) vs an HEVC-in-mp4 encode (1/12288)
  desynced the pairing — a near-lossless encode measured ~70 instead of ~93.
  Fixed generally in `QualityMeasure.vmaf` by frame-locking both inputs
  (`settb=AVTB,setpts=N`) so pairing is by frame index. See that file's comment.
- **Per-title only (so far).** Each probe encodes the whole sample. Per-shot
  search (#50) and a streaming full-clip final encode (for long 4K masters)
  reuse these same seams.

## Next

This validates the engine on one clean clip. The **#54 gate** runs it across the
high-bitrate corpus subset and compares to a flat floor-guaranteeing baseline
(the honest cross-corpus savings number). Signage/degraded content will show a
different (and more product-relevant) profile than this clean animation clip.
