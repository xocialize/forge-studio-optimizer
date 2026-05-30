# NAFNet Training Runbook (Phase B.3) — restart-friendly

Built for an Apple-Silicon laptop that **sleeps / moves mid-run**. Both long
steps (corpus generation and training) are **resumable** — re-running the same
command continues where it left off, with atomic writes so an interruption never
corrupts state. Safe to close the terminal, sleep the machine, relocate, and
resume later.

## 0. One-time setup

```bash
cd Packages/ForgeTraining
./setup.sh                                   # Python 3.12 venv + requirements.txt
source .venv/bin/activate
pip install -r requirements-parity.txt       # adds torch==2.4.1 (training + B.4 convert)
python Python/models/nafnet_torch.py         # self-test: ~1.4M params, shapes OK
```

## 1. HQ sources (one-time download)

The corpus generator tiles + degrades clean HQ images. Standard sets:
**DIV2K** (800 train) + optionally **Flickr2K**. Put the `.png`/`.jpg` files
under one dir, e.g. `data/hq-sources/`. Any folder of large clean images works.

## 2. Generate the multi-degradation corpus (resumable, ~hours)

```bash
python Python/generate_multidegradation_corpus.py \
    --hq-source data/hq-sources \
    --output    data/corpus \
    --num-pairs 500000 \
    --resume                       # ← re-run with --resume after any interruption
```

- Writes `data/corpus/pairs/{idx}_hq.png|_lq.png|_meta.json` (atomic; deterministic
  per-pair seeds). `--resume` skips completed indices and rebuilds the manifest.
- Killed by sleep? Just re-run the **identical command with `--resume`**.

## 3. Train (resumable, detached, ~2–3 days)

The launcher runs training **detached** (nohup) so it survives the terminal
closing and the laptop sleeping; **re-running `start` resumes** from the latest
checkpoint.

```bash
# from Packages/ForgeTraining
PAIRS=data/corpus/pairs OUT=runs/nafnet-b3 STEPS=300000 BATCH=16 \
  ./Scripts/train_nafnet.sh start

./Scripts/train_nafnet.sh status     # RUNNING + last log + checkpoint step/PSNR
./Scripts/train_nafnet.sh stop       # graceful: SIGTERM → it checkpoints, then exits
```

**Robustness contract** (`train_nafnet.py`):
- Atomic checkpoints (`<f>.tmp` → `os.replace`) every **500 steps** + each val + on signal.
- Auto-resume: model + optimizer + cosine scheduler + step + best-PSNR + RNG state.
- SIGINT/SIGTERM (Ctrl-C, `kill`, reaper, sleep-then-kill) → checkpoints at the next
  step boundary and exits 0. At most one step lost.
- Outputs in `runs/nafnet-b3/`: `ckpt_latest.pt` (resume), `ckpt_best.pt`,
  `nafnet_best.pt` (weights-only for the converter), `train.log`.

**Smoke first** (validate the loop on a tiny budget before committing days):
```bash
OUT=runs/nafnet-smoke STEPS=200 ./Scripts/train_nafnet.sh fg
# then kill it mid-run and re-run with `start` to confirm it resumes
```

### After a relocation / reaped run
```bash
./Scripts/train_nafnet.sh status     # see where it stopped
./Scripts/train_nafnet.sh start      # resumes from ckpt_latest.pt — no flags to remember
```

## 4. Acceptance (plan §B.3 / ADR-0003)

- Target **PSNR ≥ 35 dB** on the held-out (joint-degradation) val split.
- `train.log` flags it if best PSNR < 35 dB → ADR-0003 revisit trigger
  (upsize to `width=32, [2,2,2,2]` via `--width 32` + the wider config; the
  architecture supports it, only the checkpoint changes).

## 5. Next (B.4 → B.5)

- **B.4** (#13): convert `nafnet_best.pt` → MLX safetensors via a
  `Scripts/convert_nafnet_to_mlx.py` (mirror `convert_efrlfn_to_mlx.py`: conv
  `(O,I,kH,kW)` → `(O,kH,kW,I)`, `mx.eval` before save, PyTorch↔MLX parity test
  < 1e-2). The Swift `NAFNet` already loads via the standard MLX pipeline.
- **B.5** (#14): wire NAFNet into `PreprocessorFactory.makeChain(for:)`,
  replacing the v0.3 Denoiser/ArtifactRemover **stubs** (the 256²-resize
  placeholders — see ADR-0008 / Task #39). This is also what unblocks the
  compression-gate validation (#40).
