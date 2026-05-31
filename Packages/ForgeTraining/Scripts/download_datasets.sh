#!/usr/bin/env bash
#
# download_datasets.sh — resumable, transit-safe dataset fetcher.
#
# Same robustness as run_b3_pipeline.sh: re-run after ANY interruption (sleep,
# transit, closed lid, dropped wifi) and it RESUMES partial downloads
# (curl -C -) and SKIPS completed ones. Idempotent.
#
#   ./Scripts/download_datasets.sh corpus           # #40 benchmark corpus (the real need)
#   ./Scripts/download_datasets.sh div2k            # optional: NAFNet generalization data
#   ./Scripts/download_datasets.sh corpus div2k     # several
#   ./Scripts/download_datasets.sh all
#
# Detached so it survives the terminal closing / the machine sleeping:
#   mkdir -p runs
#   nohup ./Scripts/download_datasets.sh all > runs/download.log 2>&1 &
#   disown
# Then just re-run the same command after transit to pick up where it left off.

set -uo pipefail
RIG="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # …/Packages/ForgeTraining
REPO="$(cd "$RIG/../.." && pwd)"                          # repo root
DATA="$RIG/data/datasets"; mkdir -p "$DATA"
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Resumable zip download → unzip → flatten PNGs. Skips if already materialized.
fetch_zip() {  # name url min_png dest_subdir
  local name="$1" url="$2" minpng="$3" dest="$DATA/$4"
  local have; have="$(find "$dest" -name '*.png' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$have" -ge "$minpng" ]]; then
    log "$name: present ($have png) — skip"; return 0
  fi
  mkdir -p "$dest"
  local zip="$DATA/${name}.zip"
  log "$name: downloading (resumable, slow mirrors retry) …"
  if ! curl -C - -fSL --retry 8 --retry-delay 10 --retry-all-errors "$url" -o "$zip"; then
    log "$name: download incomplete — RE-RUN this command to resume from here."; return 1
  fi
  log "$name: unzipping → $dest"
  rm -rf "$dest.tmp"; mkdir -p "$dest.tmp"
  unzip -q -o "$zip" -d "$dest.tmp" || { log "$name: unzip failed"; return 1; }
  find "$dest.tmp" -name '*.png' -exec mv -f {} "$dest/" \;
  rm -rf "$dest.tmp"
  log "$name: ready ($(find "$dest" -name '*.png' | wc -l | tr -d ' ') png in $dest)"
}

run_one() {
  case "$1" in
    corpus)
      # The 30-clip royalty-free benchmark corpus (needed for #40's "general"
      # subset). Already-resumable + id-hardened (#37).
      log "corpus → Tests/Corpus/scripts/fetch_corpus.sh"
      ( cd "$REPO/Tests/Corpus" && ./scripts/fetch_corpus.sh )
      ;;
    div2k)
      # OPTIONAL — general-domain HQ frames for a NAFNet generalization fine-tune
      # (the deferred "add DIV2K" option, ADR-0010). ~3.3 GB, ETH mirror is slow
      # but resumable. NOT required by the current roadmap.
      fetch_zip DIV2K_train_HR \
        "http://data.vision.ee.ethz.ch/cvl/DIV2K/DIV2K_train_HR.zip" 700 div2k-hr
      ;;
    iqa)
      # OPTIONAL — external NR-IQA dataset for a robust SigLIP2 NR-IQA head (#23).
      # No clean direct-curl URL is hard-coded (KonIQ-10k / SPAQ / PIPAL are behind
      # GDrive/Baidu/registration). Set IQA_URL to a commercial-use set's zip and
      # re-run. NOTE: the NR-IQA *gate* the research wants can instead train on our
      # OWN degradation corpus (license-clean, domain-matched) — no download.
      if [[ -n "${IQA_URL:-}" ]]; then fetch_zip iqa "$IQA_URL" 1 iqa
      else log "iqa: set IQA_URL=<zip> to fetch, or train the gate on data/corpus (no download)"; fi
      ;;
    *) log "unknown target '$1' — use: corpus | div2k | iqa | all"; return 1 ;;
  esac
}

targets=("$@")
[[ ${#targets[@]} -eq 0 ]] && targets=(corpus)
[[ "${targets[0]:-}" == "all" ]] && targets=(corpus div2k)
for t in "${targets[@]}"; do run_one "$t" || log "($t had an issue — re-run to resume)"; done
log "done. Re-run the same command to resume anything interrupted."
