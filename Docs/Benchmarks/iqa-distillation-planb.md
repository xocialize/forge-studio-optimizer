# IQA Plan-B — QualiCLIP+ → MobileNet-V3 distillation (#23, Phase E) — RESEARCH ARTIFACT

Date: 2026-06-02. Status: **pipeline validated; DECIDED research-only — NOT productized.**

> **Decision (2026-06-02):** SigLIP2 (Plan A) already delivers the quality + functions we
> need (gate SRCC 0.902), so this distilled Plan-B is **kept out of the product** to avoid the
> CC-BY-NC license exposure entirely. The work lives on branch `research/iqa-distillation-planb`
> as a **reference comparison** in case we ever want it. Because nothing derived ships, the
> #30 legal review is **moot** unless this is reactivated.

## Why this exists (it's insurance, not a blocker)
SigLIP2 NR-IQA (ADR-0005) is **Plan A and ships** — it's the Step-3 restoration gate (video,
#51) and ImageBridge's restoration gate, validated at gate SRCC 0.902 (ADR-0016). Its one
operational risk is the **~400 MB lazy-download UX** (P95 >10 s on cellular, Survey-1 risk).
Plan-B is a **5–10 MB bundleable** NR-IQA head distilled from a strong teacher, as insurance
against that download being untenable in production. No permissive ≤10 MB model hits SRCC
≥0.88 on KonIQ-10k off the shelf (Survey 1), so the route is *distill*, not *swap*.

## ⚠️ Licensing — read before shipping (task #30)
- **Teacher = QualiCLIP+** (CLIP RN50 + prompt tuning), **CC-BY-NC-4.0 → non-commercial.**
  Running it as a research experiment (generating pseudo-labels off-device) is permitted by
  the license. The teacher weights themselves can NEVER ship.
- **Student = MobileNet-V3-small + 2-layer MLP** (architecture MIT). Trained weights are
  MVS's own artifact — **but** "derived from a CC-BY-NC teacher" is a real legal question.
  **#30 legal review must clear before the student ships commercially.** Until then this is
  an off-device research result only.

## Pipeline (`Scripts/distill_iqa_student.py`)
1. **Teacher pseudo-labels** — QualiCLIP+ (`torch.hub miccunifi/QualiCLIP`, CLIP mean/std,
   224 center-crop) scores each corpus image → a quality pseudo-label in ~[0,1]
   (clean > degraded; e.g. clean_signage 0.182 vs blurred 0.140). Cached to skip the slow
   CLIP pass on re-runs.
2. **Student** — `mobilenet_v3_small` (ImageNet-pretrained) features → 576-d → MLP(128)→1.
   Standard ImageNet preprocess; targets standardized (z-score; SRCC is rank-invariant).
3. **Distill** — AdamW, MSE(student, teacher_z). Best checkpoint by val student↔teacher SRCC.
4. **Eval** — SRCC/PLCC of the student against the teacher on a held-out split. High here =
   the student successfully absorbed the teacher (distillation fidelity).

## Pipeline validation (local signage corpus — no registration-gated data)
Corpus: `data/iqa_ds2/tiles` (4197 varied-degradation signage tiles from #56 — quality spread
makes SRCC meaningful). Teacher = QualiCLIP+ pseudo-labels; student = MobileNet-V3-small.

| metric | value |
|---|---|
| student↔teacher SRCC (val) | **0.920** |
| student↔teacher PLCC (val) | **0.905** |
| teacher score spread (min/mean/max/std) | 0.020 / 0.327 / 0.907 / 0.222 |
| student size | **1.00 M params (~2.0 MB FP16)** |
| corpus | `data/iqa_ds2/tiles` — 4197 varied-degradation signage tiles (#56) |
| run | 4000 imgs, 20 epochs, MPS; teacher pass 13 s (cached) |

> This validates the distillation **mechanics**: a ~2 MB MobileNet-V3 student reproduced the
> teacher's quality ranking at SRCC 0.92 on held-out signage — well under the 5–10 MB bundle
> target. It does NOT establish the headline SRCC-vs-human-MOS number (that needs KonIQ/SPAQ).

## If reactivated (the work to make it a real shippable alternative)
1. **Headline SRCC-vs-human-MOS** — fetch KonIQ-10k (train+test) and SPAQ (both
   GDrive/registration-gated; `download_datasets.sh` has no clean URL), retrain on QualiCLIP+
   pseudo-labels **+ KonIQ MOS**, report SRCC on the KonIQ test split (≥0.85) and SPAQ (≥0.83)
   separately (not averaged).
2. **#30 legal review** — clear the CC-BY-NC-derived-student question for commercial release.
3. **Dual-colour branch** (LAR-IQA) + MLX-Swift port of the student for on-device use.

**As of 2026-06-02 this is shelved as a research comparison, not on the product path.** SigLIP2
is Plan A and sufficient; revisit only if SigLIP2's lazy-download proves untenable in production.
