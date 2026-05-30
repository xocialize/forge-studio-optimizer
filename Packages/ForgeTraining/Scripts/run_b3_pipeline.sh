#!/usr/bin/env bash
#
# run_b3_pipeline.sh — end-to-end, resumable NAFNet B.3 pipeline.
#
# Runs the three long stages back-to-back, each independently resumable:
#   1. DIV2K HQ sources  (resumable download + unzip; skipped if present)
#   2. Multi-degradation corpus  (generator's --resume; skips completed pairs)
#   3. NAFNet training  (train_nafnet.py auto-resume from ckpt_latest.pt)
#
# Built for a laptop that sleeps/moves: re-running this script after ANY
# interruption picks up each stage where it left off. Launch detached so it
# survives the terminal closing:
#
#   nohup ./Scripts/run_b3_pipeline.sh > runs/b3_pipeline.log 2>&1 &
#
# Tunables via env:  PAIRS (default 200000) · STEPS (default 300000) · BATCH (16)

set -euo pipefail
RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HQ="$RIG/data/hq-sources"
CORPUS="$RIG/data/corpus"
RUN="$RIG/runs/nafnet-b3"
ZIP="$RIG/data/DIV2K_train_HR.zip"
PAIRS="${PAIRS:-200000}"
STEPS="${STEPS:-300000}"
BATCH="${BATCH:-16}"
DIV2K_URL="http://data.vision.ee.ethz.ch/cvl/DIV2K/DIV2K_train_HR.zip"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

[[ -d "$RIG/.venv" ]] || { echo "venv missing — run ./setup.sh + pip install -r requirements-parity.txt" >&2; exit 1; }
# shellcheck disable=SC1091
source "$RIG/.venv/bin/activate"
mkdir -p "$HQ" "$RIG/data" "$RUN"

# ── Stage 1: DIV2K HQ sources (resumable) ──────────────────────────────────
if [[ "$(find "$HQ" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')" -lt 700 ]]; then
  log "Stage 1: fetching DIV2K (~3.3 GB, resumable)…"
  curl -C - -fSL --retry 5 --retry-delay 10 "$DIV2K_URL" -o "$ZIP"
  log "unzipping…"
  unzip -q -o "$ZIP" -d "$HQ.tmp"
  # DIV2K zips to DIV2K_train_HR/*.png — flatten into $HQ
  find "$HQ.tmp" -name '*.png' -exec mv -f {} "$HQ/" \;
  rm -rf "$HQ.tmp"
  log "DIV2K ready: $(find "$HQ" -name '*.png' | wc -l | tr -d ' ') images"
else
  log "Stage 1: HQ sources present ($(find "$HQ" -name '*.png' | wc -l | tr -d ' ') images) — skip"
fi

# ── Stage 2: multi-degradation corpus (resumable) ──────────────────────────
log "Stage 2: corpus → $PAIRS pairs (--resume)…"
python "$RIG/Python/generate_multidegradation_corpus.py" \
  --hq-source "$HQ" --output "$CORPUS" --num-pairs "$PAIRS" --resume
log "corpus: $(find "$CORPUS/pairs" -name '*_hq.png' 2>/dev/null | wc -l | tr -d ' ') pairs on disk"

# ── Stage 3: NAFNet training (resumable) ───────────────────────────────────
log "Stage 3: training → $STEPS steps (auto-resume from ckpt_latest.pt)…"
python "$RIG/Scripts/train_nafnet.py" \
  --pairs "$CORPUS/pairs" --out "$RUN" --steps "$STEPS" --batch "$BATCH"

log "B.3 pipeline complete. Best checkpoint: $RUN/nafnet_best.pt (→ B.4 conversion)"
