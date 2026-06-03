# ADR 0024 — Extract a shared `format-bridge` package (Forge ↔ forge-studio)

**Date**: 2026-06-02
**Status**: Proposed — **forge-studio side is extraction-ready; cross-repo execution pending**
(needs the Forge monorepo in hand + an org decision on the shared-package home).
**Driven by**: #45; the Provenance note ("FormatBridge + FFmpegXC are a self-contained copy of
the shared video engine; extracting a shared package is a future cleanup").

---

## Context

`Packages/FFmpegXC` (vendored LGPL-safe FFmpeg 7.1.1 + dav1d/vpx/opus/**SVT-AV1**) and
`Packages/FormatBridge` (decode via FFmpeg + encode via VideoToolbox; ~3,750 LoC) were copied
from `xocialize-code/Forge` at the 2026-05-29 relocation. There are now **two copies** of the
video engine. Two facts decide the path:

1. **The unit is already cleanly separable.** FormatBridge depends only on FFmpegXC; FFmpegXC
   has no SPM deps. FormatBridge imports nothing forge-studio-specific (only AVFoundation /
   CoreMedia / CoreVideo / VideoToolbox / Foundation / os / FFmpegXC) — it's a pure **leaf**.
   Consumers (ForgeOptimizer, ForgeUpscaler, ImageBridge) depend on it one-way. No coupling to
   clean up.

2. **forge-studio's copy has DIVERGED — it is now the source of truth.** Since the relocation
   the copy here gained, in order:
   - #48 VideoToolbox constant-quality encoder (ADR-0013) + BT.709 tag/convert
   - #49 VMAF-targeted quality search; #50 histogram ShotDetector
   - **#32 AVAssetWriter interleave deadlock fix** (a real bug; defer-don't-block)
   - #52 AV1 Phase A; **#61 untagged-source BT.709 decode tagging**
   - **#58 in-process SVT-AV1 encode** (`FFmpegAV1Encoder`) + SVT-AV1 added to the FFmpegXC build
   Forge's copy lacks all of these. So extraction must take **forge-studio as the basis**;
   Forge migrates *to* it (not the reverse), or the bug fixes + AV1 silently regress.

## Decision (proposed)

1. **Create a standalone `format-bridge` package in its own git repo**, seeded from
   **forge-studio's** `FFmpegXC` + `FormatBridge` (the ahead copy). Both products consume it as
   a **versioned SPM remote dependency** (semver tags), replacing the in-tree `path:` packages.
2. **forge-studio is the basis**; the divergence list above is the floor — the shared package
   must contain all of it on day one.
3. **Vendored `.a` stays gitignored**; the shared repo carries `build.sh` + the recipe (incl.
   SVT-AV1), and consumers run it (or a CI job publishes prebuilt libs as a release artifact).
   The LGPL-safe / GPL-clean build invariant (no x264/x265/fdk_aac symbols) is part of the
   shared package's CI gate.
4. **Keep the public API surface stable** at extraction (no rename churn) so the consumer diff
   is just the `Package.swift` dependency swap.

## Consequences

- One source of truth for the engine; the #32 deadlock fix, color-correctness (#61), and AV1
  (#52/#58) stop being forge-studio-only.
- Both repos switch `.package(path: "../FormatBridge")` → `.package(url: <repo>, from: "x.y.z")`.
- A version bump in the shared package is a deliberate, reviewable event for both consumers
  (vs. today's silent copy drift).
- The FFmpeg rebuild story is centralized (one `build.sh`, one GPL-clean gate).

## What's done here vs. pending

- **Done (this ADR / #45 prep):** verified forge-studio's `{FFmpegXC, FormatBridge}` is a clean,
  self-contained, leaf unit with no upward coupling; catalogued the divergence that the
  extraction must carry; chose the approach (standalone versioned SPM package, forge-studio as
  basis).
- **Pending (cross-repo, needs the Forge monorepo + org decision):** create the repo, seed from
  forge-studio, tag v-initial, switch both products' `Package.swift`, retire the two in-tree
  copies, wire the shared CI (build + GPL-clean gate).

## Revisit triggers

- Forge gains its own engine changes → reconcile into the shared package before extraction (the
  divergence becomes bidirectional).
- If a third consumer appears, the shared-package case strengthens.

## References

- #45; CLAUDE.md Provenance; [ADR-0013](0013-videotoolbox-first-ship-encoder.md),
  [ADR-0017](0017-av1-tier-svtav1-subprocess-phase-a.md) (SVT-AV1 in the build), the divergence
  commits above.
