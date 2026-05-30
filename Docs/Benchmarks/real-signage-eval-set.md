# Real-Signage Eval Set — IBM Think 26 (local, proprietary)

**Status**: selection finalized 2026-05-29; materialization deferred to after the close-out items.
**Owner**: Dustin / MVS Collective

## Purpose

A 12-clip **local** evaluation set of *real* digital-signage content (IBM Think 26
show, produced by MVS Collective) to complement the synthetic 30-clip royalty-free
corpus. Real signage is the primary Marquee use case; the synthetic corpus
under-represents it. Used for:

- **Playback SR validation** at real-content quality (downscale→SR→VMAF vs the 4K master).
- **The HD→4K product test** — once each clip has a Vimeo HD (1080) + 4K-optimized
  pair, run Vimeo-HD → Forge-SR → compare against the 4K master *and* Vimeo-4K
  ("can Forge make the HD look like native 4K?").
- **Compression validation (#40)** — once NAFNet lands, compare Forge bitrate-at-
  equal-VMAF vs Vimeo's encode on real signage (the §4 `≥50% signage @Maximum` gate).

## ⚠️ Licensing — DO NOT COMMIT THE CLIPS

This is proprietary IBM client content with third-party brand IP (Ferrari,
Wimbledon, Honda, etc.). **The clips stay off-repo** — local eval + off-device
Phase-F training only (the `ForgeTraining` rig is never shipped by design). Only
*this spec* (the selection + rationale) is committed. Materialize into a local,
gitignored dir (e.g. `Forge/Tests/Corpus/clips-real/`).

## Selection (12 clips, one per SR/compression challenge)

Source root: `~/DEV_INT/IBM Think 26 Digital Signage Content/`

| id | challenge axis | source file | res | dur | trim→ |
|---|---|---|---|---|---|
| 01_gradient | smooth gradient / abstract (easy anchor) | TP_LayersB_v2_reformatted.mp4 | 4K | 11s | — |
| 02_structure | line / structural motion graphics | TP_Architecture_v2_reformatted.mp4 | 4K | 12s | — |
| 03_particle | fine particle / organic high-freq | TP_EmergingForms_v2_reformatted.mp4 | 4K | 12s | — |
| 04_characters | flat-color illustration / characters | 260504_D_Think_IBMPlayCharacters-2.mp4 | 4K | 16s | — |
| 05_3d | 3D geometric depth | 260504_D_Think_IBMAbacus-3.mp4 | 4K | 20s | — |
| 06_text_promo | large display text / promo | TP_Think2027promo-v2_reformatted.mp4 | 4K | 15s | — |
| 07_dense_text | dense product/announce text (Phase-F case) | TP_announce_watsonxOrchestrate_v2_reformatted.mp4 | 4K | 27s | 15s |
| 08_logo | brand logo / client spot, sharp flat edges | TP_Honda_v1_reformatted.mp4 | 4K | 34s | 15s |
| 09_sports_motion | high-motion sports composite | AISC_Ferrari_speed_V02_reformatted.mp4 | 4K | 71s | 15s |
| 10_camera | real camera footage (true photographic texture/noise — hardest) | IMG_3141.MOV | 4K60 | 13s | — |
| 11_portrait_text | portrait keynote text (form-factor + text) | IS_keynote_Tuesday-1 AIRace_v3.mp4 | 1080×1920 | 42s | 15s |
| 12_people | people / faces / crowd (human-subject SR) | AISC_Sevilla_players_V02_reformatted.mp4 | 4K | 68s | 15s |

**Trim**: clips over ~20s should be trimmed to ~15s on materialization (the SR pass
runs ~7 fps at 4K output, so long clips are slow to benchmark; 15s is plenty).

### Coverage rationale

- **Difficulty spread** (makes the mean + spread discriminative): easy gradient
  (~99 VMAF measured) → mid motion-graphics/text (~98) → hard photographic
  (camera footage, faces — real texture, expected lower). Without the hard cases
  the average is flatteringly high (the synthetic corpus's 78 was the opposite
  problem — pessimistic).
- **Content mix** matches deployed signage: 4 motion-graphic/abstract (the bulk),
  3 text (Phase-F relevance), 3 photographic (hardest SR), 1 illustration, 1 logo.
- **Form factors**: 10× landscape 4K, 1× portrait HD, 1× 4K60 camera.
- **Vimeo pairs**: create a 1080p + 4K-optimized for each so the HD→4K product
  test and the compression comparison both have ground truth.

## Measured so far (3 of the 12, shipped SRVGGNet-general, downscale÷4→SR×4)

| clip | VMAF |
|---|---|
| 06_text_promo | 97.84 |
| 04_characters | 99.74 |
| (IBMFlow motion-gfx, not in final 12) | 99.54 |

Headline: the shipped playback SR holds **97.8–99.7 VMAF on real signage incl.
text** → the PRD VMAF ≥ 90 gate is comfortably met on representative content, and
**Phase F (text-aware SR) is lower-priority than planned** — base SR already
reconstructs display text near-perfectly. (4K-output throughput ~7 fps reconfirms
the #41 finding: 4K SR is not realtime.)

## Materialize (when ready)

1. Copy the 12 into a gitignored local dir; trim the marked ones to ~15s.
2. Create Vimeo 1080p + 4K-optimized pairs for each (Dustin).
3. Build a local manifest (same schema as `Forge/Tests/Corpus/manifest.json`,
   `category: "signage-real"`); run `forge-benchmark-runner --playback-backend all`.
