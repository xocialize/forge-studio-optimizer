# ForgeUpscaler — Model License Audit

**Decision (2026-05-26 PM, ADR-0006)**: **Adopt EfRLFN (MIT, arXiv 2602.11339, ICLR 2026) behind a feature flag in the playback tier.** External research delivered the same day identified EfRLFN as a permissive non-NTIRE alternative; SPANV2's NTIRE-win speed advantage comes largely from a CUDA fused kernel that won't port to Metal. ADR-0004's 2026-07-15 calendar hold is superseded.

The Phase C.1 audit findings below (SPANV2 / PDS / PKDSR status) remain accurate as a license posture record — but they're no longer the *gating* dependency for the playback-tier swap.

This file documents the upstream-model license posture for everything ForgeUpscaler bundles or considers bundling. License findings cite the LICENSE file (or SPDX identifier) directly; paraphrase only where verbatim text is unavailable.

---

## 1. Currently bundled (no change this phase)

### SRVGGNetCompact (playback tier — held)

- **Status**: Held. Continues to back `PlaybackUpscaler` (`Sources/ForgeUpscaler/Playback/PlaybackUpscaler.swift`).
- **Upstream**: [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) (BSD-3-Clause) — SRVGGNetCompact is defined in the Real-ESRGAN repository under the same license.
- **Bundled weights**: Per [`Sources/ForgeUpscaler/Resources/MODELS.md`](Sources/ForgeUpscaler/Resources/MODELS.md), only `realesrgan_x{2,4}.mlpackage` (RRDBNet, vendored from `xocialize-code/com.xocialize.coreml@3989123`) are currently in `Resources/`. SRVGGNet `.mlpackage` files are referenced in code (`SRVGGNet_general_x{2,4}`, `SRVGGNet_anime_x4`) but **not yet vendored**. This is a known gap flagged in `MODELS.md`; the C.1 decision does not change the gap, only confirms we don't fill it with SPANV2.
- **SPDX**: `BSD-3-Clause`.
- **Commercial use**: Permitted with attribution and standard 3-clause notices.

### Real-ESRGAN RRDBNet (export tier — adopted Phase D, ADR-0007)

- **Status**: **In use** as of 2026-05-27 per [ADR-0007](../../Docs/ADRs/0007-real-esrgan-export-tier.md). Backs `ForgeUpscaler.RealESRGAN_CoreML` (`Sources/ForgeUpscaler/Export/RealESRGAN_CoreML.swift`).
- **Upstream**: [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN), BSD-3-Clause. Copyright © 2021 Xintao Wang.
- **Vendored from**: `xocialize-code/com.xocialize.coreml@3989123`, `models/macos/realesrgan_x{2,4}.mlpackage` (Phase 0.D, ADR-0001 §1).
- **SPDX**: `BSD-3-Clause`.
- **Commercial use**: Permitted with the standard 3-clause attribution and notices.
- Phase D rejected the alternative `themindstudio/RealESRGAN-x4plus-mlx` MLX port — no Swift loader, no safetensors, stale repo. See ADR-0007 for the full rationale.

---

## 1B. Phase C playback baseline — SRVGGNetCompact variants (BSD-3-Clause)

**Status**: Adopted as the Phase C.4 A/B baseline per ADR-0006 §"Ship criterion" — the model EfRLFN must beat to ship. Vendored at FP16 from upstream's PyTorch checkpoints (Real-ESRGAN release `v0.2.5.0`) via [`Packages/ForgeTraining/Scripts/convert_srvggnet_to_mlx.py`](../ForgeTraining/Scripts/convert_srvggnet_to_mlx.py) (Task #28).

These are the original SRVGGNetCompact variants from `xinntao/Real-ESRGAN`. They share the same authorship + license chain as the Phase D Real-ESRGAN RRDBNet entry in §1B above (renumbered here as §1C to disambiguate — see below); the architecture is the playback-tier complement to the RRDBNet export-tier model.

| Property | `realesr-general-x4v3` | `realesr-general-wdn-x4v3` | `realesr-animevideov3` |
|---|---|---|---|
| Content target | General photos / video | General + WDN training | Anime video (real-time) |
| `num_feat` × `num_conv` | 64 × 32, PReLU | 64 × 32, PReLU | 64 × 16, PReLU |
| Params | 1,213,296 | 1,213,296 | 621,424 |
| Upstream filename | `realesr-general-x4v3.pth` | `realesr-general-wdn-x4v3.pth` | `realesr-animevideov3.pth` |
| Upstream size | 4,885,111 B (~4.66 MB) | 4,885,111 B (~4.66 MB) | 2,504,012 B (~2.39 MB) |
| Upstream SHA-256 | `8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292` | `1641f8c4464b9f097c9fdda5589273713f67cf59f3d909e0bd688f0cee269dca` | `b8a8376811077954d82ca3fcf476f1ac3da3e8a68a4f4d71363008000a18b75d` |
| Vendored MLX (FP16) | `realesr_general_x4.safetensors` (~2.4 MB) | `realesr_general_wdn_x4.safetensors` (~2.4 MB) | `realesr_anime_x4.safetensors` (~1.2 MB) |
| Vendored SHA-256 | `023fa2d1f2047a0dba25be184344a0da0cb41cc8fd61d46b3912bc02161d778f` | `ef1e5aed2589c944a02c407b2c934dbeda7e9e69ab66019d7bed49c6f9c553ae` | `f8fd57a35951cd8e6eb7d54ef674ba4ba17f65278670449beb757eb8f487e00f` |

### Source URLs

- **Primary (xinntao GitHub releases, BSD-3-Clause)** — for all three files:
  - `https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth`
  - `https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-wdn-x4v3.pth`
  - `https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth`
- **Fallback (leonelhs HF mirror)** — MIT mirror packaging, weights inherit BSD-3-Clause from upstream:
  - `https://huggingface.co/leonelhs/realesrgan/resolve/main/<filename>`

### License & attribution

- **Upstream**: [`xinntao/Real-ESRGAN`](https://github.com/xinntao/Real-ESRGAN) — `BSD-3-Clause`. © 2021 Xintao Wang and Real-ESRGAN authors.
- **Architecture**: `realesrgan/archs/srvgg_arch.py` — covered by the same upstream LICENSE.
- **SPDX**: `BSD-3-Clause`.
- **Commercial use**: Permitted with standard 3-clause attribution and notices. The leonelhs HF mirror declares MIT for its repo packaging metadata, but the weights themselves inherit the upstream BSD-3-Clause — the conservative SPDX to ship with the binary is BSD-3-Clause.
- **Architecture-port note**: the MLX-Swift port (`Sources/ForgeUpscaler/Playback/SRVGGNetCompact.swift`) is a verbatim re-implementation of the upstream `srvgg_arch.py` forward pass + state-dict layout. The vendored safetensors are FP16 conversions of the upstream `.pth` checkpoints; no fine-tuning, no architectural changes.

### Relationship to ADR-0006 ship criterion

These weights are the **baseline** the Phase C.4 A/B compares EfRLFN against. Per ADR-0006:

> EfRLFN ships to default if and only if both: VMAF ≥ +1.0 vs SRVGGNetCompact on a curated 100+ clip UGC short-form benchmark; throughput parity or better on M4 Pro at 1080p → 4K.

The vendoring of these three variants closes the open gap noted in §1 of this file ("SRVGGNet `.mlpackage` files referenced but not vendored") — the Swift code (`PlaybackUpscaler.swift`) can now wire to these in the Phase C.5 integration task once C.4 picks a winner. They remain the explicit fallback on the ladder if EfRLFN does not clear the +1.0 VMAF gate.

### Attribution text to ship with binaries

> SRVGGNetCompact variants (realesr-general-x4v3 / realesr-general-wdn-x4v3 / realesr-animevideov3) © 2021 Xintao Wang and Real-ESRGAN authors. Licensed under the BSD-3-Clause License. https://github.com/xinntao/Real-ESRGAN

---

## 1A. New playback-tier candidate (post-research, 2026-05-26 PM)

### EfRLFN (Bogatyrev et al., Lomonosov MSU, ICLR 2026)

- **Status**: Adopted as Phase C.2 target per [ADR-0006](../../Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md).
- **Paper**: arXiv:2602.11339 (ICLR 2026).
- **License (code + weights)**: `MIT`.
- **Architecture**: **503,894 trainable params, ~1.0 MB FP16** (verified at C.2 port 2026-05-27 — paper abstract said ~300K but upstream `code/model.py` default config lands at ~504K). Pure conv + ECA (Efficient Channel Attention with fixed k_size=3, NOT the standard log2(C)/γ formula) + tanh activation. No exotic ops; ports to MLX directly. See [ADR-0006 §"Verified at port"](../../Docs/ADRs/0006-phase-c-unfreeze-efrlfn.md).
- **Reported performance**: Outperforms NVIDIA VSR, SPAN, and stock RLFN on user-preference-vs-runtime Pareto, validated by a crowd study with 3,800+ participants on the StreamSR benchmark.
- **Training data — cleared 2026-05-28**: StreamSR is a 5,200-video YouTube-derived dataset. The **model weights** are MIT and now confirmed usable for both inference and fine-tuning per MVS Collective legal review (Task #19, resolved 2026-05-28). Constraint: the StreamSR dataset itself does NOT get vendored / uploaded / shipped — only the trained weights. This matches the existing corpus pattern. Phase C.4 A/B + Phase C.5b ship are no longer gated on this review; fine-tuning paths are unlocked but not planned for the 2026 Q2 refresh scope.
- **Ship criterion**: VMAF ≥ +1.0 vs SRVGGNetCompact on a 100+ clip UGC short-form benchmark at M4 Pro throughput parity.

### Fallback ladder (if EfRLFN A/B underperforms)

1. **SAFMN++** — `sunny2109/SAFMN`, MIT. AIS 2024 1st-place fidelity track on AVIF compressed images. ~150–240K params, ~0.6–1 MB FP16.
2. **SPAN baseline** — Apache-2.0. NTIRE 2024 overall winner. CoreML port via ModelPiper proves Apple Silicon viability.
3. **Hold SRVGGNetCompact** — current default (BSD-3-Clause).

---

## 1B. Phase D — Export tier (adopted 2026-05-27, ADR-0007)

### Real-ESRGAN RRDBNet via CoreML mlpackages

The Phase D selection between the plan's primary MLX port and the vendored CoreML mlpackages resolved in favour of CoreML. See [ADR-0007](../../Docs/ADRs/0007-real-esrgan-export-tier.md) for the full evaluation.

| Property | Value |
|---|---|
| Backend in code | `ForgeUpscaler.RealESRGAN_CoreML` |
| Conformer to | `ForgeUpscaler.ExportTier` (`name = "real-esrgan-coreml"`) |
| Upstream | [`xinntao/Real-ESRGAN`](https://github.com/xinntao/Real-ESRGAN) |
| Upstream copyright | © 2021 Xintao Wang and Real-ESRGAN authors |
| Upstream LICENSE | `BSD-3-Clause` |
| Vendoring source | [`xocialize-code/com.xocialize.coreml`](https://github.com/xocialize-code/com.xocialize.coreml) |
| Vendored SHA pin | `3989123` |
| Vendored path | `models/macos/realesrgan_x{2,4}.mlpackage` |
| In-repo path | `Packages/ForgeUpscaler/Sources/ForgeUpscaler/Resources/realesrgan_x{2,4}.mlpackage` |
| Size on disk | 1.2 MB (x2) + 2.4 MB (x4) = ~3.6 MB total |
| SPDX | `BSD-3-Clause` |
| Commercial use | Permitted with standard 3-clause attribution and notices |

### Rejected alternative — `themindstudio/RealESRGAN-x4plus-mlx`

| Property | Value |
|---|---|
| URL | [huggingface.co/themindstudio/RealESRGAN-x4plus-mlx](https://huggingface.co/themindstudio/RealESRGAN-x4plus-mlx) |
| Declared license | `bsd-3-clause` (HF metadata; no LICENSE file in repo, README defers to upstream) |
| Reason rejected | No Swift loader; weights ship as Python `.npz` pickle only (no safetensors / no `config.json`); repo dormant ~5 months; would require from-scratch MLX-Swift RRDBNet port to adopt |
| Revisit trigger | Per ADR-0007: if upstream ships a Swift loader **or** safetensors **or** a more active MLX-community fork emerges with weights ≤100 MB + Swift example |

### Attribution text to ship with binaries

The Real-ESRGAN BSD-3-Clause license requires copyright preservation in source and binary redistributions. Bundled `.mlpackage` files retain the upstream `LICENSE` notice via the `com.xocialize.coreml` vendoring chain. Apps embedding ForgeUpscaler should surface the following in their "Licenses" or "Acknowledgements" UI:

> Real-ESRGAN © 2021 Xintao Wang and Real-ESRGAN authors. Licensed under the BSD-3-Clause License. CoreML conversion via xocialize-code/com.xocialize.coreml. https://github.com/xinntao/Real-ESRGAN

---

## 2. Investigated for the playback-tier swap (pre-research findings; kept for record)

### SPANV2 (NTIRE 2026 ESR winner, team XiaomiMM)

- **Investigated**: 2026-05-26.
- **Repo (umbrella)**: [Amazingren/NTIRE2026_ESR](https://github.com/Amazingren/NTIRE2026_ESR), last commit Feb 6 2026 (challenge launch).
- **Umbrella LICENSE**: MIT. The LICENSE file at [`Amazingren/NTIRE2026_ESR/LICENSE`](https://raw.githubusercontent.com/Amazingren/NTIRE2026_ESR/main/LICENSE) is the standard MIT text, copyright 2026 Bin Ren. SPDX: `MIT`. Commercial use permitted.
- **SPANV2 implementation in the repo**: **Absent.** The repo currently includes only the **SPAN baseline** (team00) — not SPANV2. README confirms: *"baseline ... SPAN (Cheng Yan, 2024), the 1st place for the overall performance of NTIRE2024 Efficient Super-Resolution Challenge"*.
- **SPANV2 pre-trained weights**: **Not published.** The arXiv:2604.03198 paper states *"The codes and the corresponding pre-trained weights will be available in this repository later"* (HTML version v1, retrieved 2026-05-26). No release tag exists. The Releases tab reads "No releases published".
- **`model_zoo/` contents** (retrieved 2026-05-26): only `team00_SPAN.pth` (baseline). No XiaomiMM, BOE_AIoT, or PKDSR submissions yet.
- **License rationale (if/when released)**: If SPANV2 weights drop under the umbrella MIT, they would be commercial-compatible and adoptable. **But that has not happened yet.**
- **Caveats anticipated when weights arrive**:
  - Weights will land as FP32 PyTorch `state_dict`s; Phase C.3 (`convert_spanv2_to_mlx.py`) must convert to MLX `.safetensors`.
  - `span_attn_op` is a fused CUDA kernel — does **not** port to Metal directly. The paper itself attributes much of SPANV2's runtime advantage to this kernel. MLX-Swift's `mx.compile` is the substitute, but the fusion advantage on Apple Silicon is unverified (this is Risk #2 in the coding plan §5 and explicitly the C.4 decision gate).

### PDS — Pruned + Distilled SPANF (team BOE_AIoT, 2nd place)

- **Investigated**: 2026-05-26.
- **Standalone repo**: **None identified.** The arXiv:2604.03198 team description (Section 4.2) provides no repository URL.
- **Weights**: **Not published.** Not present in the umbrella `model_zoo/`. No separate distribution channel located.
- **License**: **Unknown.** No license declaration was located. If PDS code/weights are eventually contributed back to `Amazingren/NTIRE2026_ESR`, they would inherit the umbrella MIT; otherwise the license is undetermined.
- **Architecture summary** (per paper §4.2): SPANF with channel pruning 32 → 20 in the final layer, distilled on DIV2K + LSDIR with L1.

### PKDSR — Progressive KD super-resolution (3rd place)

- **Investigated**: 2026-05-26.
- **Standalone repo**: **None identified.** Paper §4.3 provides no repo URL and does not name the team's affiliation.
- **Weights**: **Not published.** Not in the umbrella `model_zoo/`. No separate distribution channel located.
- **License**: **Unknown.** Same situation as PDS.
- **Architecture summary** (per paper §4.3): SPANF two-stage channel pruning 32 → 28 → 24 with separate distillation rounds.

### Architecture spec (available now, even without weights)

- The arXiv:2604.03198 paper (v1, 2026-04-03) does describe the SPANV2 architecture in enough detail to *re-implement* without weights:
  - Near-pixel upsampling branch, initialized as nearest-neighbor upsampling.
  - 5 × SPABV2 blocks at 32 channels for deep feature extraction.
  - SPABV2 replaces SPAB's parameter-free attention with a **learned 1×1 projection** producing a full channel-mixing map → content-adaptive suppression + cross-channel gating.
  - 48-channel near-pixel features + 32-channel deep features concatenated and refined by depthwise-separable convolution.
  - PixelShuffle ×4 reconstruction head.
  - CUDA-only `span_attn_op` kernel-fusion is an implementation detail of the attention path; the math is independent of the kernel.
- "Train SPANV2 from scratch (~14 days on M5 Max)" is the documented fallback at the bottom of the C.1 ladder. **Not invoked by this ADR**; held in reserve.

---

## 3. Decision rationale (summary)

A commercial-compatible weight release is the binding gate for C.1. **No SPANV2 weights are publicly downloadable as of 2026-05-26**, and the two fallback models (PDS, PKDSR) have neither standalone code releases nor any published weights. Training SPANV2 from scratch is a 14-day option not budgeted into the current sprint window.

The conservative call is to **hold SRVGGNetCompact** in the playback tier for now and re-check the upstream repo on **2026-07-15**, plus opportunistically whenever the NTIRE 2026 CVPRW poster session lands (typical pattern: top teams release code shortly after CVPRW). See ADR-0004 for the full decision record.

---

## 4. Source URLs and retrieval dates

| URL | Retrieved | Finding |
|---|---|---|
| https://github.com/Amazingren/NTIRE2026_ESR | 2026-05-26 | MIT umbrella, no SPANV2/PDS/PKDSR weights, no releases |
| https://raw.githubusercontent.com/Amazingren/NTIRE2026_ESR/main/LICENSE | 2026-05-26 | MIT, © 2026 Bin Ren |
| https://github.com/Amazingren/NTIRE2026_ESR/tree/main/model_zoo | 2026-05-26 | Only `team00_SPAN.pth` (baseline) |
| https://arxiv.org/abs/2604.03198 | 2026-05-26 | "The Eleventh NTIRE 2026 Efficient Super-Resolution Challenge Report" (Bin Ren et al., 2026-04-03) |
| https://arxiv.org/html/2604.03198v1 | 2026-05-26 | SPANV2 description, statement that weights "will be available later" |
| https://huggingface.co/themindstudio/RealESRGAN-x4plus-mlx | 2026-05-27 | BSD-3-Clause metadata, no LICENSE file, no safetensors / Swift loader — rejected per ADR-0007 |
| https://huggingface.co/themindstudio/RealESRGAN-x4plus-mlx/tree/main | 2026-05-27 | Single 67 MB `.npz`, no `config.json`, no Swift example |
| https://github.com/xinntao/Real-ESRGAN | 2026-05-27 | BSD-3-Clause upstream — both candidates derive from this |
| https://github.com/xocialize-code/com.xocialize.coreml/tree/3989123/models/macos | 2026-05-27 | Vendored mlpackages (`realesrgan_x{2,4}`), BSD-3-Clause |

---

## 5. Revision history

- **2026-05-26** — Initial audit. Decision: hold SRVGGNetCompact; revisit C.1 on 2026-07-15. (ADR-0004)
- **2026-05-26 PM** — External research delivered. Decision flipped: adopt EfRLFN (MIT) behind feature flag. ADR-0004 superseded by ADR-0006. SAFMN++ + SPAN added as fallback ladder. Source: [Docs/Research/research-2026-05-26-three-surveys.md](../../Docs/Research/research-2026-05-26-three-surveys.md).
- **2026-05-27** — Phase D export-tier backend resolved. Vendored CoreML `realesrgan_x{2,4}.mlpackage` adopted over the `themindstudio/RealESRGAN-x4plus-mlx` port (no Swift loader, no safetensors, stale repo). ADR-0007 documents the decision and revisit triggers. Section 1B added; the "Phase D-targeted" note in §1 flipped to "in use".
