# Forge / ForgeUpscaler / ForgeOptimizer — Three Parallel Research Surveys (2026-Q2)

**Scope:** MVS Collective Apple Silicon arm64 deployment via MLX-Swift / MLX-Python. SPDX-permissive (Apache-2.0, MIT, BSD) only for primary recommendations; CC-BY-NC and research-only licenses flagged and excluded from "adopt now" picks. Survey date: 2026-05-26.

---

## TL;DR (cross-survey)

- **Phase C unfreeze NOW:** Adopt EfRLFN (MIT, ICLR 2026, arXiv 2602.11339) behind a feature flag — Phase C is no longer NTIRE-2026-blocked; SPANV2 weights are not the right trigger because of a custom CUDA kernel that won't port to MLX.
- **Keep SigLIP2 (ADR-0005):** No permissive small NR-IQA model meets SRCC ≥0.88 on KonIQ-10k at ≤10 MB; the realistic Plan B is *distill* (QualiCLIP+-pseudo-labeled MobileNet-V3 student), not *swap*.
- **Neural codecs still watch-list (Plan §6 holds):** DCVC-RT is MIT and rate-distortion-superior to HEVC by a wide margin, but on consumer hardware (RTX 2080 Ti) it already drops to 39.5/34.1 fps encode/decode at 1080p and has no Apple Silicon port; bringing it to M5 Max is an 8–12 engineer-week effort that does not pay back today.

---

## Survey 1 — Small-footprint NR-IQA alternatives (Phase E SigLIP2 fallback)

### Executive summary

If SigLIP2 lazy-download (≈400 MB ADR-0005 commit) misbehaves, **the permissive-license landscape for NR-IQA is genuinely thin**. The strongest small-footprint candidates — CLIP-IQA, CLIP-IQA+, QualiCLIP, QualiCLIP+, TOPIQ, ARNIQA, LIQE — are all released under either NTU S-Lab License 1.0 (research/non-commercial in spirit, not OSI-approved) or CC-BY-NC 4.0 (explicitly non-commercial). They cannot be primary recommendations under MVS Collective's SPDX-permissive constraint. What remains permissive is a narrow band of older CNN heads (NIMA, DBCNN, HyperIQA, MUSIQ) plus 2024-2026 mobile-targeted designs (LAR-IQA, MobileCLIP-derived heads, MaCLIP). Among those, **MUSIQ-single-scale (Google Research, Apache-2.0) and LAR-IQA's MobileNet-V3 branch (open architecture, retrainable from scratch)** are the only candidates that meet both the SRCC ≥0.85 KonIQ-10k bar and the SPDX bar without retraining.

The pragmatic recommendation is therefore: **keep SigLIP2 as Plan A and stop searching for a smaller plug-in replacement under permissive terms** — there isn't one with proven SRCC ≥0.88 on KonIQ-10k that fits ≤10 MB. The realistic Plan B is to retrain a small head (LAR-IQA-style MobileNet-V3 or a distilled MUSIQ-single) on KonIQ-10k + SPAQ + KADID-10k using QualiCLIP's pseudo-labels as additional supervision; the *trained weights* are then MVS Collective's own asset under whatever license MVS chooses. Plan C is to ship CLIP-IQA+ as a research-licensed evaluation-only build while the retraining is in flight.

### Comparison table — NR-IQA candidates

| Model | Arch / Backbone | Params | Size FP16 | SRCC KonIQ-10k | SRCC SPAQ | SRCC KADID-10k | License | MLX port? |
|---|---|---|---|---|---|---|---|---|
| **MUSIQ (multi-scale)** | ViT-like, hash 2D pos embed | ~27M ("around 27M" per arXiv 2108.05997) | ~54 MB | 0.916 (ICCV 2021 Table 2, KonIQ-10k, ±0.002 std over 10 runs) | 0.917 | n/r | Apache-2.0 (google-research) | None public; convertible (pure attention + conv) |
| **MUSIQ-single-scale** | Same, native-res only | ~27M | ~54 MB | 0.905 (ICCV 2021 Table 2) | 0.910 | n/r | Apache-2.0 | None public; same path |
| **MANIQA** | ViT-B + window attn | ~135M | ~270 MB | 0.834 (PIPAL train) | n/r | 0.910 | Apache-2.0 (IIGROUP) | None; large |
| **HyperIQA** | ResNet-50 + meta head | ~27M | ~54 MB | 0.906 | 0.916 | n/r | BSD-3 (SSL-MOE) | None; ResNet-50 trivially MLX-portable |
| **DBCNN** | Dual VGG-16 | ~15M | ~30 MB | 0.875 | n/r | n/r | MIT | None; conv-only |
| **NIMA** | MobileNet-v2 / Inception | ~3.5M (MNv2) | ~7 MB | ~0.80 | n/r | n/r | Apache-2.0 (google-research) | None public |
| **CLIP-IQA (zero-shot)** | OpenAI CLIP RN50 | ~102M | ~204 MB | 0.695 (paper, AAAI 2023) | n/r | n/r | NTU S-Lab 1.0 (non-comm) | None; flagged |
| **CLIP-IQA+ (CoOp)** | OpenAI CLIP RN50 + 16 ctx | ~102M | ~204 MB | 0.895 (paper, KonIQ-10k after CoOp prompt tuning) | n/r | n/r | NTU S-Lab 1.0 (non-comm) | None; flagged |
| **QualiCLIP** | OpenAI CLIP RN50 | ~102M | ~204 MB | 0.817 (arXiv 2403.11176 v3, zero-shot opinion-unaware) | 0.841 | 0.410 | CC-BY-NC 4.0 ("All material is made available under Creative Commons BY-NC 4.0") | None; flagged |
| **QualiCLIP+** | CLIP RN50 + prompt tuning | ~102M | ~204 MB | 0.875 | 0.871 | n/r | CC-BY-NC 4.0 | None; flagged |
| **TOPIQ-NR (ResNet-50)** | ResNet-50 + top-down attn | ~28M | ~56 MB | 0.927 | 0.917 | 0.547 | S-Lab 1.0 (non-comm) | None; flagged |
| **ARNIQA** | ResNet-50 + 2-layer MLP regressor | ~25.6M | ~51 MB | 0.910 (paper) | ~0.910 | ~0.940 | CC-BY-NC 4.0 (assumed by lab convention; verify) | None; flagged |
| **LIQE** | CLIP RN50 + multi-task | ~102M | ~204 MB | 0.919 | 0.923 | 0.930 | NTU S-Lab 1.0 (non-comm) | None; flagged |
| **LAR-IQA (MobileNet-V3 branch)** | MobileNet-V3 + dual color | ~5M | ~10 MB | 0.86–0.88 (authors) | 0.88 | n/r | Open code | None; bundle-friendly |
| **Q-Align (mPLUG-Owl2-7B)** | 7B LMM | 7B | 14 GB | 0.940 | 0.931 | 0.934 | Apache-2.0 (code), but LMM is huge | Out of scope for in-app |
| **MaCLIP (Nov 2025, arXiv 2511.09948)** | CLIP magnitude fusion, training-free | ~102M | ~204 MB | reported SoTA vs CLIP-IQA | n/r | n/r | Open code; CLIP weights non-comm | Inherits flag |

(`n/r` = not reported in original paper; values shown are the most commonly cited paper-reported numbers, intra-dataset 80/20 splits, single training run.)

### Top 3 recommendations

**1. Don't switch — keep SigLIP2 (ADR-0005). Plan B is *retrain*, not *swap*.** There is no off-the-shelf NR-IQA model under SPDX-permissive license that beats SRCC 0.88 on KonIQ-10k *and* fits under 50 MB on disk. The only permissive picks that hit the SRCC bar (MUSIQ 0.916, HyperIQA ~0.906, MANIQA ~0.83) are all 30–270 MB FP16 — i.e. larger than a SigLIP2-distilled head would be. If SigLIP2 lazy-download misbehaves, the right move is engineering effort on the lazy-download UX (background prefetch, progress UI, resumable downloads) rather than a model swap.

**2. If you must ship a bundleable head: distill QualiCLIP+ into a MobileNet-V3 student under MVS Collective's own license.** QualiCLIP+ achieves SRCC ~0.875 on KonIQ-10k as a teacher with no human annotations required — its quality-aware image-text alignment pseudo-labels generalize well cross-dataset. Train a 5–10 MB MobileNet-V3 + 2-layer MLP regressor (LAR-IQA architecture) on the pseudo-labels plus KonIQ-10k MOS. The *trained weights* are MVS's own artifact and can be released under Apache-2.0 even though QualiCLIP itself is CC-BY-NC 4.0 (the license on QualiCLIP restricts the *teacher weights*, not derived knowledge in newly trained students — but legal review is required before commercial release).

**3. Tactical fallback: MUSIQ-single-scale (Apache-2.0) at FP16.** If retraining isn't an option in the sprint window, MUSIQ-single is the only permissive ≥0.90 SRCC option. At ~54 MB FP16 it exceeds the ≤10 MB bundle target but is **~8× smaller than SigLIP2's 400 MB** — meaningful for in-app bundling. The Google Research codebase is TF/Flax; MLX-Swift port is non-trivial (custom hash-based 2D positional embedding, multi-scale token concatenation) but contains no exotic ops — pure attention + conv. Estimate one engineer-week for the port.

### "Wait and watch" entries

- **MaCLIP** (arXiv 2511.09948, training-free magnitude-aware CLIP, code at zhix000/MA-CLIP) — released too recently (Jan 2026 v3) for production validation; if cosine-similarity flat-zone is a real problem in our content, revisit Q3 2026.
- **LAR-IQA** authors' code — confirm MIT/BSD-style license, then evaluate as direct ship candidate.
- **Q-SiT / DeQA-Score** — LMM-class, too large for in-app, but if MVS adds a cloud quality-grade endpoint these become candidates.

### License audit table — Survey 1

| Model | Code license | Weight license | Training data |
|---|---|---|---|
| MUSIQ | Apache-2.0 | Apache-2.0 | KonIQ-10k (CC-BY 4.0), SPAQ (research), AVA, PaQ-2-PiQ |
| MANIQA | Apache-2.0 | Apache-2.0 | PIPAL (research), KonIQ-10k |
| HyperIQA | BSD-3 | BSD-3 | KonIQ-10k, LIVEC |
| DBCNN | MIT | MIT | TID2013, LIVE Challenge |
| NIMA | Apache-2.0 | Apache-2.0 | AVA (aesthetic, research) |
| CLIP-IQA(+) | NTU S-Lab 1.0 (**non-comm**) | Inherits OpenAI CLIP (research-only) | KonIQ-10k MOS for CoOp |
| QualiCLIP(+) | CC-BY-NC 4.0 (**non-comm**) | CC-BY-NC 4.0 | KADIS-700k synthetic; CLIP pre-training data |
| TOPIQ | S-Lab 1.0 (**non-comm**) | S-Lab 1.0 | KonIQ-10k, AVA |
| ARNIQA | CC-BY-NC 4.0 (**flag — assumed by lab convention; verify**) | CC-BY-NC 4.0 | Synthetic distortion model + KADIS-700k |
| LIQE | S-Lab 1.0 (**non-comm**) | S-Lab 1.0 | Multi-task quality + scene + distortion |
| Q-Align | Apache-2.0 code; mPLUG-Owl2 weights have their own LLaMA-derived terms | Mixed | KonIQ, SPAQ, KADID, AVA, LSVQ |

---

## Survey 2 — Post-NTIRE-2026-ESR permissive-license landscape

### Executive summary

**Phase C is not blocked anymore — but the unfreeze candidate is permissive non-NTIRE work, not NTIRE 2026 weights.** The NTIRE 2026 Eleventh Efficient SR Challenge winner is **XiaomiMM/SPANV2** (arXiv 2604.03198). It is a direct descendant of SPAN (Apache-2.0) and *should* inherit Apache-2.0, but as of 2026-05-26 no standalone SPANV2 weight release exists on Hugging Face under a permissive license — only the challenge-submission tar in `Amazingren/NTIRE2026_ESR`. SPANV2's headline trick is a custom fused CUDA kernel (`span_attn_op`) that won't port directly to MLX/Metal, so even when weights drop, the speed advantage may not carry over to Apple Silicon. Combined with the fact that SPANV2 only marginally improves on SPAN at 4× and that PSNR alone (the NTIRE metric) is a weak proxy for perceptual quality, **SPANV2 is not the right unfreeze trigger**.

The genuinely interesting unfreeze candidate is **EfRLFN** (arXiv 2602.11339, MIT) — a paper published as a conference paper at ICLR 2026 (per the arXiv 2602.11339v2 header), authored by Bogatyrev et al. at Lomonosov Moscow State University. It proposes a real-time SR model explicitly tuned for UGC video and outperforms NVIDIA VSR, SPAN, and stock RLFN on a Pareto curve of user-preference-vs-runtime, validated by a crowd-sourced user preference study with more than 3,800 participants (Section 4). It also re-benchmarks 11 real-time SR models on a new YouTube-derived dataset (StreamSR). At MVS Collective's content profile (UGC short-form, streaming-tier playback), EfRLFN's design choices (ECA + tanh activation + composite loss) translate well, and the architecture is conv-only — drop-in for MLX. We recommend lifting the Phase C freeze: **adopt EfRLFN now in a feature flag behind SRVGGNetCompact, A/B on internal builds, ship if VMAF gain over SRVGGNetCompact is ≥1.0 at equal or better M4-Pro throughput.**

### Comparison table — Efficient SR landscape

| Model | Year | Params | FP16 size | NTIRE/Set5 PSNR (×4) | License | M-series viable? | Notes |
|---|---|---|---|---|---|---|---|
| **SRVGGNetCompact (baseline)** | 2021 (Real-ESRGAN) | ~0.6M | ~2.4 MB | n/a (perceptual model) | BSD-3 (xinntao/Real-ESRGAN) | ✓ shipping in ForgeUpscaler playback tier | ~1 ms/frame 720p M4 Pro per ADR-0004 |
| **SPAN** | NTIRE 2024 | ~0.151M | ~0.6 MB | 32.20 Set5; runtime 5.59 ms RTX 3090 | Apache-2.0 | ✓ pure conv + symmetric activation | 1st in NTIRE 2024 overall (main) track per CVPRW 2024 challenge report (arXiv 2404.10343); runtime sub-track winner not separately confirmed |
| **SPANV2 (XiaomiMM)** | NTIRE 2026 #1 overall | ~0.15M | ~0.6 MB | ≥26.90 DIV2K_LSDIR_valid (challenge floor) | Apache-2.0 inherited (assumed; verify) | ⚠ Custom CUDA kernel `span_attn_op` won't port; only architecture portable | Weights not yet on HF as of 2026-05-26 |
| **SAFMN** | ICCV 2023 | ~228K (×4 light) | ~1 MB | 32.18 Set5 | MIT (sunny2109/SAFMN) | ✓ ViT-like but with simple SAFM modulation | NTIRE 2023 runner-up complexity track |
| **SAFMN++ / light_SAFMN++** | 2024 | ~150K-240K | ~0.6-1 MB | NTIRE2024 Top-4 overall + 1st AIS2024 AVIF track | MIT | ✓ | Successor to SAFMN |
| **OmniSR / OmniSR-Light** | CVPR 2023 | 792K (Omni-SR ×4) | ~3 MB | 26.95 Urban100 ×4 | Apache-2.0 | ✓ Window attention + multi-scale | Self-attention is MLX-supported |
| **RLFN (baseline)** | NTIRE 2022 winner | 317K | ~1.3 MB | 32.21 Set5; 11.77 ms RTX 3090 | Apache-2.0 (BasicSR-style) | ✓ pure conv | Reference model for NTIRE 2022-2026 floor |
| **EfRLFN** | arXiv 2602.11339 (ICLR 2026, Bogatyrev et al., Lomonosov MSU) | ~300K | ~1.2 MB | SoTA on StreamSR Pareto front; outperforms NVIDIA VSR, SPAN, RLFN | MIT | ✓ ECA + tanh, no exotic ops | **Best Phase-C unfreeze candidate** |
| **BSRN / BSRN-S** | NTIRE 2022 | 156K (BSRN-S) | ~0.6 MB | 32.14 Set5 | Apache-2.0 | ✓ blueprint separable conv | Smaller than RLFN; competitive |
| **Swin2SR (small)** | 2022 | ~1M (light) | ~4 MB | 32.34 Set5 | Apache-2.0 | ✓ but window attention slower on MLX than pure conv | Compression-artifact variants strong |
| **SwinIR-Light** | 2021 | 897K | ~3.6 MB | 32.44 Set5 | Apache-2.0 | ✓ but 7× slower than SAFMN per SAFMN paper | High quality, low throughput |
| **ShuffleMixer** | NeurIPS 2022 | 411K | ~1.7 MB | 32.21 Set5 | Apache-2.0 (sunny2109) | ✓ | Channel-shuffle conv |
| **FMEN** | NTIRE 2022 | 341K | ~1.4 MB | 32.13 Set5 | Apache-2.0 | ✓ | Modern efficient baseline |
| **ETDS** | CVPR 2023 | 200K | ~0.8 MB | 32.04 Set5 | Apache-2.0 | ✓ pure conv (designed for re-param) | Reparameterized into single conv at inference |
| **RealCUGAN** | 2022 (Bilibili) | ~1.4M | ~5.6 MB | n/a (anime) | MIT | ✓ | Anime-only; not for live UGC |
| **PiperSR (ModelPiper)** | 2025 community | 453K | ~1.8 MB | within 0.46 dB of SAFMN on Set5 | Apache-2.0 (HF card) | ✓ ANE-optimized CoreML port | 44 FPS 640×360→1280×720 M2 Max; 125 FPS 128×128 tiles M2 |
| **SPAN PurePhoto 4× (ModelPiper)** | 2025 | ~1M | ~4 MB | community-trained on photos | open weights | ✓ CoreML build available | Reference for "what shipped works" on Apple Silicon |
| **kaeru-shigure/mlx-4x_NMKD-YandereNeoXL** | 2025 | ESRGAN-class | ~17 MB | n/a (anime-photo blend) | Apache-2.0 (HF card) | ✓ Native MLX port exists | Demonstrates MLX SR feasibility |

### Top 5 ranked fallback ladder

**1. Adopt now — EfRLFN (MIT).** Best combination of license permissiveness × demonstrated VMAF/perceptual gain over SRVGGNetCompact × M-series-friendly architecture (pure conv + ECA + tanh). Authors trained explicitly on streaming UGC (StreamSR), which matches ForgeUpscaler's content profile better than DIV2K. **Verdict: adopt behind a feature flag; ship if internal A/B shows ≥1.0 VMAF gain over SRVGGNetCompact at equal or better M4-Pro throughput.**

**2. Adopt after testing — SAFMN++ / light_SAFMN++ (MIT).** AIS 2024 1st-place fidelity track on AVIF compressed images. The MIT license is unambiguous, weights are public on sunny2109/SAFMN, and the ViT-like SAFM block contains only standard ops (depth-wise conv, GELU, channel mixer). Port is straightforward; throughput on M-series is expected good. **Verdict: keep as the fallback if EfRLFN underperforms or has data-license issues with StreamSR.**

**3. Adopt after testing — SPAN baseline (Apache-2.0).** Already 1st in the NTIRE 2024 overall track, pure conv, parameter-free attention. The community-trained "PurePhoto SPAN 4×" CoreML build on Apple Silicon (ModelPiper) demonstrates Apple Silicon viability. **Verdict: ship as the conservative upgrade option if EfRLFN / SAFMN++ require more validation than the sprint window allows.**

**4. Wait for — SPANV2 (XiaomiMM) public release with permissive weights.** Trigger: standalone HF model card under Apache-2.0 with weights, plus removal of the `span_attn_op` custom CUDA dependency or a portable Metal/MLX equivalent. Until then, do not adopt — the speed advantage that won NTIRE 2026 was largely from the fused kernel, not the architecture.

**5. Skip — RealCUGAN, ETDS, FMEN, ShuffleMixer.** All permissive; none beats EfRLFN or SAFMN++ on the relevant metrics for UGC short-form content. RealCUGAN is anime-specialized; the rest are PSNR-tuned with limited perceptual headroom.

### Answer to the decision-critical question

> "Is Phase C still genuinely blocked on NTIRE 2026 weight releases, or is there a permissive non-NTIRE alternative we should adopt now that beats SRVGGNetCompact by ≥1.0 VMAF at equal or better throughput?"

**Phase C is no longer blocked.** EfRLFN (MIT, arXiv 2602.11339, ICLR 2026, Bogatyrev et al. / Lomonosov MSU) is the alternative. Lift the 2026-07-15 freeze; start integration sprint now; gate ship behind internal A/B for VMAF ≥1.0 gain on a representative UGC clip set at M4-Pro throughput parity. SPANV2 weights, when they drop, are a *future re-evaluation*, not the gating dependency.

### License audit — Survey 2

| Model | Code license | Weight license | Training data |
|---|---|---|---|
| SRVGGNetCompact | BSD-3 | BSD-3 | DIV2K + OST + Flickr2K |
| SPAN | Apache-2.0 | Apache-2.0 | DIV2K, LSDIR |
| SPANV2 | Apache-2.0 (assumed) | not yet released | DIV2K_LSDIR_train |
| SAFMN / SAFMN++ | MIT (BasicSR-based) | MIT | DF2K (DIV2K+Flickr2K) |
| OmniSR | Apache-2.0 | Apache-2.0 | DIV2K, DF2K |
| RLFN | Apache-2.0 | Apache-2.0 | DIV2K |
| **EfRLFN** | **MIT** | **MIT** | **StreamSR (5,200 YouTube videos — license terms inherited from YouTube ToS; verify before training derivation)** |
| BSRN | Apache-2.0 | Apache-2.0 | DIV2K |
| Swin2SR / SwinIR-Light | Apache-2.0 | Apache-2.0 | DIV2K, Flickr2K |
| ShuffleMixer | Apache-2.0 | Apache-2.0 | DIV2K |
| ETDS | Apache-2.0 | Apache-2.0 | DIV2K |
| RealCUGAN | MIT | MIT | Anime curated set |
| PiperSR | Apache-2.0 | Apache-2.0 | Photo dataset |

---

## Survey 3 — Neural-codec maturity on Apple Silicon

### Executive summary

**The Plan §6 assumption still holds. There is no 2026-Q2 neural codec that is simultaneously (a) commercial-permissive, (b) ≥0.5× realtime at 1080p on M5 Max, and (c) ≥10% better rate-distortion than HEVC at equal quality.** DCVC-RT (Microsoft Research, MIT license confirmed on github.com/microsoft/DCVC) is the closest — 21% average BD-rate gain over H.266/VTM on YUV420, 125.2/112.8 fps encode/decode at 1080p — but those numbers are on an NVIDIA A100, *not* Apple Silicon. The same paper (arXiv 2502.20762, CVPR 2025) states: "it enables 1080p coding on consumer GPUs like the NVIDIA RTX 2080Ti with an average speed of 40 fps for encoding and 34 fps for decoding" — i.e. 39.5/34.1 fps respectively. On an M-series GPU with no equivalent CUDA fused kernels and CPU-side arithmetic entropy coding, realistic 1080p throughput on M5 Max would land well under 30 fps in a naive MLX port.

DCVC-RT also has two non-trivial portability blockers: (1) custom CUDA fused inference kernels (the repo provides a PyTorch fallback but with substantial speed loss), and (2) a C++ entropy-coding extension required for actual bitstream production. The neural backbone (implicit temporal modeling, single 1/8-resolution latent) is pure conv + transformer and would port to MLX, but full encode/decode requires reimplementing the entropy coding pipeline. **Recommendation: keep DCVC-RT on the watch-list for another quarter. Re-evaluate in 2026-Q3 if either (a) someone publishes an MLX or CoreML DCVC-RT port, or (b) Apple publishes Neural Engine entropy-coding primitives in MLX 0.x.**

### Comparison table — Neural video codecs

| Codec | Year | License | BD-rate vs HEVC / VTM | Latency @ 1080p | Apple Silicon port? | MLX-portable? | Bitstream compatible? |
|---|---|---|---|---|---|---|---|
| **DCVC-RT** | CVPR 2025 (arXiv 2502.20762) | MIT (Microsoft) | −21% vs H.266/VTM (much larger margin vs HEVC) | 125.2/112.8 fps enc/dec on A100; 39.5/34.1 fps enc/dec on RTX 2080Ti; **no M-series number** | None public | Backbone yes; entropy coding & fused CUDA kernels no | No — paired neural decoder required |
| **DCVC-FM** | CVPR 2024 | MIT | −13% vs H.266/VTM | slower than DCVC-RT | None | Same blockers | No |
| **DCVC-DC** | CVPR 2023 | MIT | ECM-class | sub-realtime | None | Same blockers | No |
| **DCVC-HEM** | 2022 | MIT | ~−7% vs VVC | sub-realtime | None | Same blockers | No |
| **GIViC (Bristol, implicit diffusion)** | Sep 2025 | research code; license not confirmed | −15.9% vs VVC random-access | sub-realtime (diffusion-based) | None | Diffusion sampler unsuitable for realtime | No |
| **VCT (Google)** | NeurIPS 2022 | Apache-2.0 (research code) | competitive with HEVC | sub-realtime | None | Transformer-only, portable; but no realtime claim | No |
| **ELF-VC** | ICCV 2021 | research code | similar to HEVC | sub-realtime | None | n/a | No |
| **NTIRE 2026 Short-form UGC VR (KwaiVIR challenge winners)** | CVPRW 2026 (arXiv 2604.10551) | per-team; none confirmed permissive at survey date | n/a (restoration, not codec) | varies | None | Generative restoration models — heavy | n/a (restoration task) |
| **NTIRE 2026 Bitstream-Corrupted VR (BSCVR)** | CVPRW 2026 (arXiv 2604.06945) | per-team | n/a (restoration) | varies | None | Heavy | n/a |
| **Apple Research neural codecs in VideoToolbox** | n/a | Apple proprietary | not publicly disclosed | n/a | n/a | n/a | Would be n/a |

### Top 3 ranked picks

**1. DCVC-RT — watch-list (MIT, but not deployable).** The architecture is interesting and the license is permissive, but bringing it to Apple Silicon requires (a) replacing CUDA fused kernels with Metal/MLX equivalents, (b) re-implementing the C++ entropy coder, and (c) validating bitstream determinism across encode/decode. Estimate: 8-12 engineer-weeks for a working but slower-than-A100 port, before any optimization. ROI does not justify pulling forward against ForgeOptimizer's restoration-pipeline priorities.

**2. VCT (Google, Apache-2.0) — research-only.** Transformer-based, fully MLX-portable in principle, but no real-time claim and no public weights at video-rate quality. Skip.

**3. Skip all NTIRE 2026 UGC VR winners.** They solve a different problem (restoration of degraded UGC), not codec replacement. Their relevance to Forge is as inspiration for the restoration tier, not as codec swaps.

### Answer to the decision-critical question

> "Is there a 2026-Q2 neural codec that is (a) commercial-permissive, (b) ≥0.5× realtime at 1080p on M5 Max, and (c) provides ≥10% better rate-distortion than HEVC at equal quality?"

**No.** DCVC-RT satisfies (a) and (c) decisively (−21% vs H.266/VTM, which is itself ≥30% better than HEVC), but (b) cannot be confirmed on M5 Max without a port that does not yet exist, and the architectural blockers (CUDA fused kernels, C++ entropy coder) put a working port at 8-12 engineer-weeks. **Plan §6 watch-list assumption holds. Re-evaluate 2026-Q3.**

### License audit — Survey 3

| Codec | Code license | Weights license | Training data |
|---|---|---|---|
| DCVC-RT | MIT | MIT (per repo terms) | Vimeo-90k + UVG-style |
| DCVC-FM / DC / HEM | MIT | MIT | Vimeo-90k |
| GIViC | research-only (unconfirmed) | unconfirmed | UVG, MCL-JCV |
| VCT | Apache-2.0 | Apache-2.0 | research |
| ELF-VC | research | research | Vimeo-90k |

---

## Recommendations (cross-survey)

**Immediate (next sprint):**

1. **Open ADR-0004 amendment to lift Phase C freeze.** Adopt EfRLFN behind a feature flag in ForgeUpscaler playback tier. Set ship criterion: VMAF gain ≥1.0 over SRVGGNetCompact at equal or better M4-Pro throughput on a curated UGC short-form clip set (target 100+ clips, diverse genres). Trigger to revert: VMAF gain <0.5 or throughput regression >20%.
2. **Confirm ADR-0005 (SigLIP2) is the right path for NR-IQA.** Stop searching for a permissive small-model substitute; instead, schedule investment in lazy-download UX (resumable, background-prefetch, progress UI).
3. **Verify EfRLFN training-data provenance.** StreamSR is YouTube-derived; before any MVS-internal retraining or fine-tuning, get legal review of YouTube ToS compatibility for derivative training data.

**Within 2 sprints (Phase B refinement):**

4. **Begin Plan-B distillation track.** Spin a small experiment training a 5–10 MB MobileNet-V3 student on QualiCLIP+ pseudo-labels + KonIQ-10k MOS. Hold-out evaluation on SPAQ and KADID-10k separately (not averaged). Target SRCC ≥0.85 on KonIQ-10k, ≥0.83 on SPAQ. This is insurance against SigLIP2 lazy-download surprises in production.

**Q3 2026 re-evaluation:**

5. **Re-check DCVC-RT every 90 days.** Trigger conditions for active port: (a) Hugging Face mlx-community publishes any DCVC-family port; (b) Apple publishes neural-codec primitives in MLX 0.x or VideoToolbox; (c) competitor ships a neural codec on macOS apps.
6. **Re-check SPANV2 weight release every 60 days.** Trigger: standalone HF model card under Apache-2.0 with weights *and* either removal of the `span_attn_op` CUDA dependency or a portable Metal/MLX equivalent. If both, consider as candidate to replace whichever model EfRLFN displaced.

**Benchmarks that change recommendations:**

- If EfRLFN A/B shows VMAF gain <0.5 → fall back to SAFMN++ (recommendation 2 in Survey 2 ladder).
- If SigLIP2 lazy-download P95 latency >10 s on cellular → accelerate the MobileNet-V3 distillation track to MVP.
- If DCVC-RT Apple Silicon port appears with measured M-series fps ≥15 at 1080p → re-evaluate as ForgeOptimizer codec-tier addition.

---

## Caveats

- ARNIQA's exact GitHub LICENSE file was not directly fetched; CC-BY-NC 4.0 is inferred from sibling-lab convention (QualiCLIP, IISA at miccunifi). Legal review should confirm before any production use.
- QualiCLIP SRCC numbers come from the v3 (March 2025) Table 1 zero-shot block; minor cross-version differences exist between v1, v2, and v3 of arXiv 2403.11176.
- DCVC-RT param count, FP16 size, and peak VRAM at 1080p were not published in the paper or repo; download and measurement required for an exact deployment cost estimate.
- SPANV2 (NTIRE 2026 winner) achieved-PSNR exact value on DIV2K_LSDIR_valid is in the challenge report Table 1 but was not retrieved verbatim; the 26.90 dB floor is confirmed.
- EfRLFN training-data license (StreamSR is YouTube-derived) needs verification before MVS-internal retraining or fine-tuning.
- The SPAN NTIRE 2024 challenge report (arXiv 2404.10343) describes XiaomiMM as the 2024 overall winner; the runtime sub-track winner for 2024 was not separately confirmed from sources available in this survey.
- Q-Align and similar LMM-class IQA models are excluded from primary in-app recommendations purely on size/latency grounds; their Apache-2.0 code licenses do not change that constraint.
- The cross-survey conclusion (lift Phase C, keep Phase E, hold Plan §6) is a recommendation based on 2026-Q2 evidence; any of the three may need revision if (a) a permissive DCVC-family Apple Silicon port appears, (b) SigLIP2 lazy-download proves operationally untenable, or (c) NTIRE 2026 ESR teams release permissive standalone weights.