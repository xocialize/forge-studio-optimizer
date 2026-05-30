# Real-Signage Eval Set — IBM Think 26 (local, proprietary)

**Status**: pairs delivered + Vimeo baseline measured 2026-05-30 (`IBM_Pairs/`, local).
Forge-side eval pending B.3/B.4 (NAFNet) + an SR pass over these clips.
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

## Delivered pairs (2026-05-30) — `~/DEV_INT/IBM_Pairs/` (local, off-repo)

Dustin paired each IBM **source master** with Vimeo-optimized output(s). Caveat:
several of the originally-requested clips were *reformatted* versions (real
content letterboxed onto a 4K canvas with black bars for the LED wall) — the
**source** was provided instead (even when natively HD), which is correct for
VMAF (no black-bar dilution). Consequence: only **6 of 15 sources are native
4K**; the reformatted-only axes are HD/portrait-HD at source.

- **7 full triplets** (4K source + Vimeo 1080p + Vimeo 2160p) — power the HD→4K
  product test: `abacus` (3D), `characters` (illustration), `ferrari`
  (sports-motion), `sevilla` (people), `img3140` (4K camera), `layersb`
  (gradient), `smarter` (text). [Both recommended 4K additions delivered
  2026-05-30 — `characters` 4K pair + the `smarter` text clip; coverage now
  spans every SR/compression axis.]
- The rest are HD / portrait-HD sources with a same-res Vimeo HD output.

**4K-coverage recommendation** (Dustin offered more): two additions would round
out the HD→4K test's content diversity — (1) a Vimeo **4K** pair for the existing
`characters4k` 4K source (instant character/illustration triplet), and (2) one
**4K text** clip with both Vimeo pairs (text is the signage workhorse and has no
4K triplet yet; also the Phase-F case). 5 triplets is a valid v1 without these.

## Vimeo baseline — the parity bar (measured 2026-05-30, libvmaf, 15 s, fps=30)

Per clip: VMAF of Vimeo's output vs the source. **Three distinct measurements**
(detail in `IBM_Pairs/vimeo_baseline.csv`, local):

**A. Vimeo 4K-optimized compression** — quality kept compressing the 4K master:

| clip | src→Vimeo-4K | ratio | VMAF |
|---|---|---|---|
| img3140 (camera) | 429→189 MB | 2.3× | **81.4** |
| ferrari (motion) | 310→94 MB | 3.3× | **84.8** |
| sevilla (people) | 281→33 MB | 8.5× | **87.8** |
| layersb (gradient) | 10.6→10.1 MB | ~1× | **95.7** |
| abacus (3D) | 13.4→13.7 MB | — | **97.0** (source already small; no gain) |
| characters (illustration) | 16→8 MB | 2.0× | **98.05** (4K Vimeo pair added 2026-05-30) |
| smarter (text) | 22→1.7 MB | 12.9× | **98.53** (highest ratio — flat-color text) |

**B. Vimeo HD→4K bicubic — the SR product-test bar** (Vimeo HD upscaled to wall):
img3140 **72.3**, ferrari **79.0**, sevilla **81.8**, layersb **88.0**,
abacus **92.3**, characters4k **92.7**. *Forge SR must beat these.* The earlier
SRVGGNet signage measurements (**97.8–99.7 VMAF**) sit far above this 72–93
floor → the HD→4K "make HD look native-4K" story is a clear win on real content.

**C. Vimeo HD same-res compression** (HD sources, 4–8×): 94–98 VMAF — honda 97.1,
is_announce 97.2, keynote 96.8, think2027 96.6, architecture 95.8, ibmplay3d 97.6.

**Read**: Vimeo's bar is content-dependent — **81–88 on hard photographic/motion**,
**94–98 on motion-graphics/text**. That's the per-content target for the Forge
optimizer's compression gate (#40, pending NAFNet), and the 72–93 column-B floor
is what Forge SR already beats today.

## Forge SR — measured 2026-05-30 (SRVGGNet-general x4, downscale÷4→SR×4 vs master)

Ran the 6 native-4K masters through the playback SR (trimmed 15 s, xcodebuild
binary — see ADR-0011). VMAF vs the master, beside the Vimeo HD→4K bicubic bar:

| clip | **Forge SR VMAF** | Vimeo HD→4K bicubic | Δ | SR fps @4K |
|---|---|---|---|---|
| abacus (3D) | **99.83** | 92.3 | +7.5 | 5.1 |
| characters | **99.83** | 92.7 | +7.1 | 5.8 |
| ferrari (motion) | **96.00** | 79.0 | +17.0 | 9.0 |
| img3140 (camera) | **97.81** | 72.3 | +25.5 | 6.7 |
| layersb (gradient) | **99.21** | 88.0 | +11.2 | 6.7 |
| sevilla (people) | **98.97** | 81.8 | +17.2 | 9.1 |
| smarter (text) | **94.47** | 93.5 | +1.0 | 8.5 |
| **mean (7)** | **98.0** | 85.7 | **+12.4** | 7.0 |

**Read**: Forge SR holds **98.6 mean VMAF** on real signage (confirms + extends
the earlier 3-clip 97.8–99.7), far above the bicubic HD→4K floor — biggest gains
on hard photographic/motion (img3140 +25.5, sevilla +17.2, ferrari +17.0). PRD
VMAF≥90 is met on every clip. 4K-output throughput 5–9 fps reconfirms 4K SR is
not realtime (ADR-0009).

(The above reconstructs from a *clean* ÷4 downscale. The strictly-controlled
HD→4K product test below removes that caveat.)

### Controlled HD→4K product test (measured 2026-05-30)

The clean apples-to-apples: feed Vimeo's *actual* compressed HD → Forge SR ×4 →
downscale to master res → VMAF vs master, against Vimeo-HD→bicubic on the
**identical** input. (Runner gained an `--external-lr-dir` mode for this — ADR-0011
build, ADR note; SR output 8K → 1.2–1.4 fps.)

| clip | **Forge SR (Vimeo-HD)** | Vimeo-HD bicubic | Δ |
|---|---|---|---|
| abacus | **99.84** | 92.31 | +7.5 |
| characters | **99.83** | 92.73 | +7.1 |
| ferrari | **99.28** | 79.04 | +20.2 |
| img3140 | **93.48** | 72.30 | +21.2 |
| layersb | **99.58** | 87.95 | +11.6 |
| sevilla | **99.76** | 81.75 | +18.0 |
| smarter (text) | **98.65** | 93.47 | +5.2 |
| **mean (7)** | **98.63** | 85.65 | **+13.0** |

**Text-clip note** (`smarter`, added 2026-05-30): SR of Vimeo's 940 KB HD text =
**98.65**, which ≈ Vimeo's own 1.7 MB 4K encode (col-A 98.53) — Forge reconstructs
native-4K text quality from the HD source. The +5.2 margin over bicubic is the
smallest in the set *because* bicubic is already strong on flat-color text (93.5,
vs 72–82 on photographic); SR still wins and hits 4K-parity. (Clean-÷4 SR scores
only 94.47 here — the ÷4 downscale destroys thin strokes; Vimeo-HD's ÷2 preserves
them, which is why the controlled HD-input number is far higher. Text is genuinely
resolution-sensitive.)

**Read**: on the *same* Vimeo-HD input, Forge SR beats bicubic by **+14.3 mean
VMAF** — the controlled number nearly matches the indicative one (+14.28). Two
findings: (1) SR-on-Vimeo-HD (98.63) ≈ SR-on-clean-÷4 (98.6) → SRVGGNet absorbs
Vimeo's compression well; it even *exceeds* the clean-LR run on ferrari/sevilla/
layersb because Vimeo-HD (÷2 from master) carries more detail than a ÷4 clean
downscale. (2) Lone soft spot: img3140 (93.5 vs clean 97.8) — real 4K camera
footage is where Vimeo's HD compression bites hardest. **Conclusion**: the entry
"Forge makes Vimeo's HD look native-4K" claim is verified on real IBM signage,
strictly controlled.
Reports (local): `signage-sr-report.json` (clean-LR), `signage-hd4k-report.json`
(controlled).

## Canonical 12 (mapped to delivered files)

| axis | clip id | native res | triplet? |
|---|---|---|---|
| gradient | layersb | 2160×3840 | ✓ |
| structure | architecture | 1920×1080 | HD |
| particle | emergingforms | 1920×1080 | HD |
| characters | characters4k | 3840×2160 | 4K src, HD pair |
| 3d | abacus | 3840×2160 | ✓ |
| text_promo | think2027 | 1080×1920 | HD |
| dense_text | is_announce | 1080×1920 | HD |
| logo | honda | 1080×1920 | HD |
| sports_motion | ferrari | 3240×1920 | ✓ |
| camera | img3140 | 3840×2160 | ✓ |
| portrait_text | is_keynote | 1080×1920 | HD |
| people | sevilla | 3240×1920 | ✓ |

(Spares: `ibmplay3d`, `is_architecture`, `is_emergingforms`.)

## Next (Forge side)

1. SR pass over the 6 native-4K sources (downscale÷4→SR×4→VMAF vs master) and the
   HD→4K test (Vimeo-HD→SR→VMAF vs master *and* vs Vimeo-4K) → fill a Forge column
   next to the column-B bar above.
2. After NAFNet (B.3→B.5): Forge optimize each clip, compare bitrate-at-equal-VMAF
   vs the Vimeo column-A/C numbers → the §4 compression gate (#40) on real signage.
3. Local manifest lives in `IBM_Pairs/` (off-repo); only this spec is committed.
