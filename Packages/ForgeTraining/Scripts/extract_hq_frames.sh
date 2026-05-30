#!/usr/bin/env bash
#
# extract_hq_frames.sh — turn a list of video masters into HQ training frames.
#
# Reads a newline-delimited MANIFEST of absolute master paths (one per line,
# '#' comments + blank lines ignored) and writes lossless PNG frames into
# OUTDIR, sampling at FPS frames/sec. Near-black frames (intro/outro fades) are
# pruned by a size heuristic.
#
# Generic + content-agnostic on purpose: the manifest (which may name
# proprietary masters) lives OUTSIDE the repo under data/. This script ships;
# the manifest does not.
#
# Restart-friendly: a clip whose frames are already present is skipped, so
# re-running after an interruption resumes cleanly.
#
#   ./Scripts/extract_hq_frames.sh data/ibm_hq_masters.txt data/hq-sources 0.75
#
# Args:  MANIFEST  OUTDIR  [FPS=0.75]  [HEAD_SKIP_SEC=2]  [MIN_PNG_BYTES=153600]

set -euo pipefail
MANIFEST="${1:?usage: extract_hq_frames.sh MANIFEST OUTDIR [FPS] [HEAD] [MINBYTES]}"
OUTDIR="${2:?usage: extract_hq_frames.sh MANIFEST OUTDIR [FPS] [HEAD] [MINBYTES]}"
FPS="${3:-0.75}"
HEAD="${4:-2}"
MINBYTES="${5:-153600}"   # 150 KB — a detailed full-res frame is MBs; near-black is tiny

[[ -f "$MANIFEST" ]] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not on PATH" >&2; exit 1; }
mkdir -p "$OUTDIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

sanitize() { echo "$1" | tr -c 'A-Za-z0-9._-' '_' | sed 's/__*/_/g;s/^_//;s/_$//'; }

total_clips=0 done_clips=0 total_frames=0
while IFS= read -r src || [[ -n "$src" ]]; do
  [[ -z "$src" || "$src" == \#* ]] && continue
  total_clips=$((total_clips + 1))
  if [[ ! -f "$src" ]]; then log "MISSING, skip: $src"; continue; fi

  base="$(sanitize "$(basename "${src%.*}")")"
  # restart-friendly: already extracted?
  existing=$(find "$OUTDIR" -maxdepth 1 -name "${base}_*.png" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$existing" -gt 0 ]]; then
    log "skip (have $existing): $base"
    done_clips=$((done_clips + 1)); total_frames=$((total_frames + existing)); continue
  fi

  log "extract: $base  (fps=$FPS)"
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -ss "$HEAD" -i "$src" \
    -vf "fps=${FPS},format=rgb24" \
    "$OUTDIR/${base}_%04d.png" < /dev/null || { log "ffmpeg FAILED: $base"; continue; }

  # prune near-black / fade frames
  pruned=0
  while IFS= read -r f; do rm -f "$f"; pruned=$((pruned + 1)); done < <(
    find "$OUTDIR" -maxdepth 1 -name "${base}_*.png" -size -"${MINBYTES}"c 2>/dev/null)
  kept=$(find "$OUTDIR" -maxdepth 1 -name "${base}_*.png" 2>/dev/null | wc -l | tr -d ' ')
  log "  kept $kept (pruned $pruned near-black)"
  done_clips=$((done_clips + 1)); total_frames=$((total_frames + kept))
done < "$MANIFEST"

log "DONE: $done_clips/$total_clips clips → $total_frames frames in $OUTDIR"
