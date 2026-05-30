# ADR 0002 — Dev-Time vs. Runtime ffmpeg Split

**Date**: 2026-05-26
**Status**: Accepted
**Branch**: `feature/forge-2026-q2-refresh`
**Owner**: Dustin / MVS Collective

---

## Context

Phase 0.C added a benchmark-corpus toolchain that depends on the `drawtext`, `drawbox`, `xfade`, `geq`, `color`, and `gradients` ffmpeg filters, the libx264 encoder, libfreetype, an `ffmpeg` CLI binary, and HTTP networking to fetch Xiph/Blender/Internet Archive clips.

The Homebrew `ffmpeg` formula was split in 2026 into a minimal `ffmpeg` (10 deps, no libfreetype, no `drawtext`) and a full-feature `ffmpeg-full` (46 deps, keg-only). Phase 0.C currently uses `ffmpeg-full`.

A natural question: the repo already vendors FFmpeg via [Packages/FFmpegXC](../../Packages/FFmpegXC) — could the corpus toolchain reuse it instead of taking a dev-machine Homebrew dependency?

## Decision

**No.** Keep `ffmpeg-full` as the dev-time tool; keep FFmpegXC as the runtime library. The two roles are intentionally disjoint and should stay that way.

## Reasoning

`Packages/FFmpegXC/build.sh` builds FFmpeg 7.1.1 with a deliberately narrow configure:

```bash
--disable-gpl --disable-nonfree                  # LGPL-only, no libx264/x265
--disable-programs                               # no ffmpeg/ffprobe CLI
--disable-network                                # no http://, https://
--disable-encoders --enable-encoder=libvpx_vp9   # decode-focused; only VP9 encode
--disable-muxers --enable-muxer=webm --enable-muxer=matroska
--disable-filters --enable-filter=scale --enable-filter=aresample --enable-filter=aformat
# (no libfreetype dependency)
```

The output is five static archives (`libavformat.a`, `libavcodec.a`, `libavutil.a`, `libswscale.a`, `libswresample.a`) plus `libdav1d.a` / `libvpx.a` / `libopus.a`. The build script's final step `nm -g libavcodec.a | grep -i 'x264\|x265\|fdk_aac'` actively gates against GPL symbol contamination.

The corpus toolchain needs the inverse of every one of those design constraints: GPL filters, GPL encoders, CLI invocations, HTTP fetches, and text-rendering filters with libfreetype.

Widening FFmpegXC to cover the corpus would:

1. Pull libx264 (GPL) in, breaking the LGPL clearance that keeps Forge App Store-distributable
2. Add libfreetype + libharfbuzz + libfontconfig, 20+ filter enables, the CLI program, and the network stack
3. Force every commercial-build CI run to also build a much larger artifact
4. Conflate "runtime library" and "dev toolchain" responsibilities in one SPM package

None of those are worth saving the user a `brew install ffmpeg-full` step.

## Boundaries

- **Runtime path (ships in Forge.app)** — FFmpegXC static libs, decode + minimal-encode, no CLI, no network, LGPL-only. Used by `Packages/FormatBridge/Sources/FormatBridge/FFmpegDecoder.swift` for input-format demuxing and decoding before handing CVPixelBuffers to ForgeOptimizer / NativeEncoder.
- **Dev/test path (host machine only)** — Homebrew `ffmpeg-full`, full filter graph, GPL allowed, used by `Forge/Tests/Corpus/scripts/*.sh` to synthesize and fetch benchmark clips. Never shipped, never linked into the app target.

## Consequences

- Phase 0.C documents `brew install ffmpeg-full` as a prerequisite for corpus reproduction
- `generate_signage.sh` / `generate_screencapture.sh` bind `FFMPEG=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg` explicitly (absolute path defeats subprocess PATH scrubbing)
- Any future tooling that wants GPL filters or libx264 encoding goes into `Forge/Tests/` or `scripts/`, never into a runtime SPM package
- LGPL clearance verification stays purely in FFmpegXC's build.sh — the corpus toolchain is out of scope for that check

## Revisit triggers

- If Apple removes VideoToolbox h.264 encoding on a future platform (very unlikely) → reconsider whether Forge needs its own libx264 in-app
- If we ever want corpus generation inside the app (also unlikely; dev tooling shouldn't move into a shipped binary) → that's the moment to widen FFmpegXC, with a separate ADR
