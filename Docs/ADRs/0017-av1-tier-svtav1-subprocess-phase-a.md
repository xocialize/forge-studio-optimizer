# ADR 0017 — AV1 export tier ships via SVT-AV1 (ffmpeg subprocess) first; in-process is Phase B

**Date**: 2026-06-01 (Phase B landed 2026-06-02)
**Status**: Accepted — **Phase B done (#58)**
**Driven by**: Step 4 (#52) — the research roadmap's AV1 opt-in export tier; builds on
ADR-0013 (VideoToolbox-first ship encoder) and ADR-0001/0002 (dev-vs-runtime ffmpeg split).

> **Update 2026-06-02 — Phase B (in-process) is done (#58).** SVT-AV1 2.3.0 (BSD, encoder-only,
> static) is now built into FFmpegXC (`--enable-libsvtav1`), and `FormatBridge.FFmpegAV1Encoder`
> does the full decode→yuv420p→libsvtav1→mp4 transcode in-process (CRF / preset / film-grain,
> tagged BT.709) — no ffmpeg subprocess. `forge-quality-target --codec av1` routes through it.
> Triggered by the deployment requirement: AV1 export must run self-contained inside the
> sandboxed app. GPL check still clean (SVT-AV1 is BSD). VMAF *measurement* remains an external
> dev-time tool (like libvmaf), which is fine. Subprocess path retired.

---

## Context

Step 4 adds an **opt-in AV1 export tier** (better compression than HEVC, especially for
signage). Two constraints decided the implementation path:

1. **No hardware AV1 encode on Apple Silicon.** `VTCompressionSessionCreate(codecType:
   kCMVideoCodecType_AV1)` returns −12908 on this M5 Max — Apple Silicon has AV1 *decode* only.
   So the VideoToolbox ship path (ADR-0013) cannot produce AV1; it must be software SVT-AV1.
2. **FFmpegXC has no AV1 encoder.** The vendored in-process ffmpeg is built `CONFIG_LIBSVTAV1=0`
   (dav1d *decode* only). An in-process AV1 encode would need a FFmpegXC rebuild with libsvtav1
   **and** a new libavcodec/libavformat encode path (FFmpegXC is decode/probe-only today).

A measure-first check (libsvtav1 vs libx265 at matched VMAF on real signage) showed AV1 is
**~44–53% smaller than HEVC** — and more vs our actual VT-HEVC encoder. Clear GO; the only
question was *how* to ship it.

## Decision

**Phase A (now): ship the AV1 tier via an ffmpeg + libsvtav1 subprocess.** Extend
`forge-quality-target` with `--codec av1`: a VMAF-targeted SVT-AV1 CRF binary search (mirroring
Step 1) plus `--film-grain` synthesis, shelling to the configured ffmpeg (same dependency the
VMAF measurement already uses). Validated end-to-end on real 4K signage (genuine AV1 output,
96–99% smaller than the masters at the VMAF floor). See `Docs/Benchmarks/av1-tier.md`.

**Phase B (deferred — end-of-roadmap polish): in-process FFmpegXC + SVT-AV1.** Rebuild
`FFmpegXC/build.sh` with `--enable-libsvtav1 --enable-encoder=libsvtav1` and add an in-process
encode path, behind the **same `--codec av1` flag** (the interface is stable across the swap).
Pull forward only if a shipping build can't depend on a system ffmpeg (Dustin's call).

## Consequences

- AV1 export works today on any machine with an ffmpeg that has libsvtav1 (dev/eval/on-prem).
  Not yet self-contained for App-Store distribution — that's Phase B.
- The CRF search spans SVT-AV1's full 18…63 range: very flat signage rides the CRF ceiling
  while still well above the VMAF floor (sevilla@95 → crf 63, VMAF 96.6), so we ship the
  smallest AV1 the encoder will make.
- Licensing: SVT-AV1 is BSD-3 + AOM patent grant (App-Store-safe). The subprocess path inherits
  whatever ffmpeg the host provides; Phase B's static FFmpegXC+SVT-AV1 keeps it permissive and
  in-binary (consistent with ADR-0001/0002's runtime-ffmpeg handling).
- Film-grain synthesis is opt-in (`--film-grain N`, denoise-then-resynthesise); off by default
  (signage is mostly grain-free).

## References

- `Docs/Benchmarks/av1-tier.md` (measurement + validated runs + the tool)
- [ADR-0013](0013-videotoolbox-first-ship-encoder.md) — VideoToolbox-first (HEVC/H.264); AV1 opt-in
- [ADR-0001/0002] — dev-vs-runtime ffmpeg LGPL split
- #52 (Step 4), #53 (Step 5/6 — x264 premium / convex-hull)
