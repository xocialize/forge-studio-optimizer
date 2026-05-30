#!/usr/bin/env bash
#
# train_nafnet.sh — robust, restart-friendly launcher for Phase B.3.
#
# Runs train_nafnet.py as a DETACHED process (nohup + disown) so it survives the
# laptop sleeping / moving and this shell closing. Re-running `start` after an
# interruption RESUMES automatically (train_nafnet.py loads ckpt_latest.pt).
#
# Usage:
#   ./Scripts/train_nafnet.sh start [-- <extra train args>]   # launch/resume detached
#   ./Scripts/train_nafnet.sh status                          # progress + checkpoint step
#   ./Scripts/train_nafnet.sh stop                            # graceful stop (saves a ckpt)
#   ./Scripts/train_nafnet.sh fg [-- <extra args>]            # run in foreground (debug)
#
# Config via env (or edit the defaults):
#   PAIRS   corpus pairs dir   (default: $RIG/data/corpus/pairs)
#   OUT     run dir            (default: $RIG/runs/nafnet-b3)
#   STEPS   total optim steps  (default: 300000)
#   BATCH   batch size         (default: 16)

set -euo pipefail

RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$RIG/.venv"
PAIRS="${PAIRS:-$RIG/data/corpus/pairs}"
OUT="${OUT:-$RIG/runs/nafnet-b3}"
STEPS="${STEPS:-300000}"
BATCH="${BATCH:-16}"
PIDFILE="$OUT/train.pid"
LOG="$OUT/train.log"

cmd="${1:-}"; shift || true
# allow `-- extra args`
[[ "${1:-}" == "--" ]] && shift || true
EXTRA=("$@")

activate() {
  if [[ ! -d "$VENV" ]]; then
    echo "ERROR: venv missing at $VENV — run ./setup.sh first" >&2; exit 1
  fi
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  python - <<'PY' || { echo "ERROR: PyTorch missing — pip install -r requirements-parity.txt" >&2; exit 1; }
import torch  # noqa
PY
}

running_pid() {
  [[ -f "$PIDFILE" ]] || return 1
  local p; p="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null && { echo "$p"; return 0; }
  return 1
}

start() {
  mkdir -p "$OUT"
  if pid="$(running_pid)"; then
    echo "already running (PID $pid). 'status' to watch, 'stop' to halt." ; exit 0
  fi
  if [[ ! -d "$PAIRS" ]] || ! ls "$PAIRS"/*_hq.png >/dev/null 2>&1; then
    echo "ERROR: no corpus pairs at $PAIRS." >&2
    echo "Generate first (resumable):" >&2
    echo "  python Python/generate_multidegradation_corpus.py --hq-source <DIV2K> --output \$(dirname $PAIRS) --resume" >&2
    exit 1
  fi
  activate
  [[ -f "$OUT/ckpt_latest.pt" ]] && echo "resuming from $OUT/ckpt_latest.pt" || echo "fresh start"
  nohup python "$RIG/Scripts/train_nafnet.py" \
      --pairs "$PAIRS" --out "$OUT" --steps "$STEPS" --batch "$BATCH" \
      "${EXTRA[@]}" >>"$LOG" 2>&1 &
  local p=$!
  disown
  echo "$p" > "$PIDFILE"
  echo "launched detached PID=$p — log: $LOG"
  echo "watch:  ./Scripts/train_nafnet.sh status"
  echo "(safe to close this terminal / let the laptop sleep; re-run 'start' to resume)"
}

status() {
  if pid="$(running_pid)"; then echo "RUNNING (PID $pid)"; else echo "not running"; fi
  if [[ -f "$OUT/ckpt_latest.pt" ]]; then
    activate 2>/dev/null || true
    python - "$OUT/ckpt_latest.pt" <<'PY' 2>/dev/null || true
import sys, torch
ck = torch.load(sys.argv[1], map_location="cpu")
print(f"checkpoint: step {ck.get('step','?')}, best_psnr {ck.get('best_psnr',-1):.3f} dB")
PY
  fi
  echo "--- last log ---"; tail -n 8 "$LOG" 2>/dev/null || echo "(no log yet)"
}

stop() {
  if pid="$(running_pid)"; then
    echo "sending SIGTERM to $pid (it checkpoints, then exits)…"
    kill -TERM "$pid"
    for _ in $(seq 1 30); do running_pid >/dev/null || { echo "stopped."; rm -f "$PIDFILE"; return 0; }; sleep 1; done
    echo "still running after 30s; check 'status'." >&2
  else
    echo "not running."
  fi
}

fg() {
  activate
  exec python "$RIG/Scripts/train_nafnet.py" \
      --pairs "$PAIRS" --out "$OUT" --steps "$STEPS" --batch "$BATCH" "${EXTRA[@]}"
}

case "$cmd" in
  start|resume) start ;;
  status)       status ;;
  stop)         stop ;;
  fg)           fg ;;
  *) echo "usage: $0 {start|status|stop|fg} [-- <extra train args>]" >&2; exit 2 ;;
esac
