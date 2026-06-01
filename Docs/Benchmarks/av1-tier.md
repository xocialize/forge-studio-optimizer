# Step 4 — AV1 export tier (#52)

**Date**: 2026-06-01 · **Status**: Phase A (SVT-AV1 via ffmpeg subprocess) shipped + validated.
In-process FFmpegXC+SVT-AV1 (Phase B) deferred as end-of-roadmap polish (ADR-0017).

## Why software AV1

Apple Silicon (incl. this M5 Max) has AV1 **decode** but **no encode** — `VTCompressionSessionCreate`
with `kCMVideoCodecType_AV1` returns −12908 (no encoder). The vendored in-process ffmpeg
(`FFmpegXC`) is built with `CONFIG_LIBSVTAV1=0` (dav1d decode only). So AV1 encode must be
**software SVT-AV1**, as the research roadmap specified.

## Does AV1 pay? (measure-first)

`libsvtav1` (preset 6) vs `libx265` (medium) at matched VMAF, on real signage (1080p, ratios
hold across resolution):

| clip | HEVC (x265) @ VMAF≈95 | AV1 (SVT) @ VMAF≈95 | AV1 savings |
|---|---|---|---|
| signage_abacus (graphics) | 533 KB | ~299 KB | **~44% smaller** |
| signage_sevilla | 576 KB | ≤322 KB (at higher VMAF) | **~44%+ smaller** |

AV1 is ~44–53% smaller than HEVC at equal quality on signage — above the textbook ~20–30%,
because signage (flat regions, text, graphics) is AV1's home turf. And this **understates** the
real win: our ship HEVC is **VideoToolbox**, which is *less* efficient than x265 medium, so AV1's
edge over our actual encoder is larger. Encode is slow (software), but Forge export is
non-realtime, so that's acceptable for an opt-in tier. **Clear GO.**

## The tier (`forge-quality-target --codec av1`)

VMAF-targeted, mirroring Step 1's design but over SVT-AV1 CRF via ffmpeg subprocess:
1. Decode a bounded sample; build a lossless reference of the same frames (#55 trim recipe).
2. Binary-search SVT-AV1 CRF (18…63) for the highest CRF (smallest file) whose sample VMAF
   clears the floor (`target − slack`).
3. Full-encode the clip at that CRF, optional **film-grain synthesis** (`--film-grain N` →
   `film-grain=N:film-grain-denoise=1`, the canonical denoise-then-resynthesise flow).

Flags: `--codec av1 --target <vmaf> --av1-preset <0..13> --film-grain <1..50> --out <path> --json`.

## Validated end-to-end (real 4K signage, this machine)

| clip | target | chosen CRF | output | savings vs source master | output codec |
|---|---|---|---|---|---|
| signage_abacus (4K, 11.8 Mbps h264) | VMAF 95 | 48 | 0.41 Mbps | **96.5% smaller** | av1 ✓ |
| signage_sevilla (4K, 11.3 Mbps h264) | VMAF 95 | 63 (ceiling) | 0.13 Mbps | **98.8% smaller** | av1 ✓ |
| signage_sevilla + `--film-grain 8` | VMAF 93 | — | 0.55 Mbps | 95.2% | av1, decodes ✓ |

(The vs-source numbers are vs the high-bitrate h264 masters — these particular signage clips are
extremely compressible flat graphics; sevilla rides AV1's CRF ceiling while still at VMAF 96.6.
The decision-relevant codec win is the **~44–53% vs HEVC** above.)

## Phase B (deferred — ADR-0017)

Ship a self-contained in-process AV1 encoder: rebuild `FFmpegXC/build.sh` with SVT-AV1
(`--enable-libsvtav1 --enable-encoder=libsvtav1`) + a libavcodec/libavformat AV1 encode path,
behind the same `--codec av1` flag. Pulled forward only if a shipping build can't depend on a
system ffmpeg (Dustin: "revisit in-process at the end as polish unless it surfaces sooner").
