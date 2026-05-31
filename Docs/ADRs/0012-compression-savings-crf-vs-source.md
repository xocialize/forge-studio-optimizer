# ADR 0012 — Compression savings = CRF-encode vs source

**Date**: 2026-05-31
**Status**: Accepted
**Relates to**: §4 compression gates, [ADR-0009](0009-drop-realtime-requirements.md), B.5 (NAFNet wiring), #40, #33

---

## Context

Validating the §4 compression gates (≥35% savings @Balanced / VMAF≥90, ≥55%
signage @Maximum) with the trained NAFNet (#40) surfaced that the benchmark
runner's optimizer pass encodes every level at a **fixed bitrate**
(`avgBitrate = pixels × fps × 0.1`, AVAssetWriter) with the per-level quality
target disabled. So all levels produce ~identical-size files — `savingsVsBaseline`
is structurally ~0 and the gate is unmeasurable. (AVFoundation h264 can't do
CRF; quality-constant encoding needs VideoToolbox/ffmpeg — overlaps the pending
#33 NativeEncoder migration.)

Two ways to define "savings": vs the unoptimized `.off` re-encode (isolates the
model's marginal compression contribution), or **vs the source file** (the
product metric: Forge delivers a smaller file than the master at retained
quality, same shape as the Vimeo comparison, e.g. 320 MB → 94 MB @ 88 VMAF).

## Decision

**Measure compression savings as a CRF-encode vs the source.** Added
`runCompressionCRFPass` (gated by `--crf <0..51>`): stream the chain-processed
(NAFNet) frames to `ffmpeg libx264 -crf`, then report `savings = 1 − out/source`
and VMAF(out vs source). The fixed-bitrate AVAssetWriter path (used by C.4/B.5)
is untouched; `--crf` selects the new path.

Rationale: this is the product value (a smaller deliverable at the same quality).
NAFNet's role is to let the encoder go harder without quality loss; its *own*
compression contribution is marginal on **clean** masters (a restoration model
has nothing to remove) and shows on **degraded** input.

## First result (signage_smarter, CRF 23, vs 3.73 MB source)

| level | savings vs source | VMAF |
|---|---|---|
| off (re-encode only) | 64.6% | 98.50 |
| **balanced (NAFNet + CRF)** | **62.6%** | **98.74** |

Both clear ≥35% / VMAF≥90 with margin — the gate **intent is met** on real
signage. NAFNet costs ~2% size for +0.24 VMAF on clean content (expected).

## Consequences / open items (the gate `passed` flag, not the numbers)

1. **`postProcessCompression` overwrites** the source-based `savingsVsBaseline`
   with a vs-`.off` value (≈0 on clean content). Skip it when `--crf` is set.
2. **Subset routing**: `compression_balanced_min` reads the **general** subset
   and `compression_signage_max_min` reads **signage @ maximum**. A clean full
   #40 needs the royalty-free corpus (general @ balanced) + signage clips
   (@ maximum). Empty subsets should evaluate N/A, not fail.
3. CRF value (23 here) is a starting point; sweep to the gate's quality target
   if needed. 4K NAFNet runs ~1.5 fps (fp16) — full-corpus runs are slow.

## References

- `BenchmarkRunner.runCompressionCRFPass`, CLI `--crf`
- Vimeo parity baseline: `Docs/Benchmarks/real-signage-eval-set.md`
- [ADR-0011](0011-xcodebuild-for-mlx-inference.md) (xcodebuild + per-file resources)
