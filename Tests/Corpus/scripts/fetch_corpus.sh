#!/usr/bin/env bash
#
# fetch_corpus.sh — Materialize the 30-clip evaluation corpus from manifest.json.
#
# Reads Forge/Tests/Corpus/manifest.json, downloads each `source_url`, transcodes
# per `fetch_notes` (interlacing / MPEG-2 / trims), invokes generate_signage.sh
# and generate_screencapture.sh for the synthesized clips, and writes
# `sha256`, `frame_rate`, `duration_s`, `codec` back into manifest.json.
#
# Downloaded clips land in Forge/Tests/Corpus/clips/ (gitignored).
#
# Usage:
#   ./scripts/fetch_corpus.sh                  # fetch all 30 clips
#   ./scripts/fetch_corpus.sh general          # fetch one category
#   ./scripts/fetch_corpus.sh --id general-film-01   # fetch one clip
#   ./scripts/fetch_corpus.sh --verify-only    # don't fetch; just re-hash & re-probe
#
# Requires: bash 4+, curl, ffmpeg, ffprobe, jq, shasum

set -euo pipefail

CORPUS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$CORPUS_ROOT/manifest.json"
CLIPS_DIR="$CORPUS_ROOT/clips"
SCRIPTS_DIR="$CORPUS_ROOT/scripts"

mkdir -p "$CLIPS_DIR"

# Sweep stale .raw download leftovers from interrupted/reaped prior runs.
# Each download writes "<id>.raw", transcodes it, then removes it; a SIGINT /
# connection reap mid-transcode (or `set -e` tripping on a bad transcode) can
# leak a multi-hundred-MB .raw. Clear them at startup — safe for the
# sequential usage this script is built for.
rm -f "$CLIPS_DIR"/*.raw 2>/dev/null || true

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
require curl
require jq
require shasum

# Prefer ffmpeg-full (keg-only, drawtext + 46-dep build). Fall back to
# plain ffmpeg on the PATH if ffmpeg-full isn't installed. Signage tier
# enforces drawtext availability via generate_signage.sh's precondition.
if [[ -x /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ]]; then
  export PATH="/opt/homebrew/opt/ffmpeg-full/bin:$PATH"
fi
require ffmpeg
require ffprobe

FILTER_CATEGORY=""
FILTER_ID=""
VERIFY_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) FILTER_ID="$2"; shift 2 ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    --help|-h) sed -n '2,/^$/p' "$0"; exit 0 ;;
    general|signage|legacy) FILTER_CATEGORY="$1"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

fetch_one() {
  local id="$1" category="$2" subcategory="$3" source_url="$4" notes="$5"

  # Guard against corrupted clip ids. An intermittent runtime gremlin (seen
  # during reaped/interrupted runs) occasionally delivered a truncated id to
  # this function — e.g. "al-sports-01" for "general-sports-01" — which then
  # wrote a junk-named file ("al-sports-01.mp4") AND a no-op manifest
  # writeback (the truncated id matches no clip, so the real clip stayed
  # unpopulated). Reject any id that isn't an exact, whole-line match for a
  # real manifest clip id, so a bad read skips cleanly instead of silently
  # corrupting the corpus. VALID_IDS is computed once from the manifest below.
  if ! grep -qxF -- "$id" <<< "$VALID_IDS"; then
    echo "  [SKIP] refusing unknown/corrupted clip id: '${id}'" >&2
    return
  fi

  local out="$CLIPS_DIR/${id}.mp4"

  if [[ $VERIFY_ONLY -eq 1 ]]; then
    [[ -f "$out" ]] || { echo "  [$id] file missing; skipping verify"; return; }
  elif [[ -f "$out" ]]; then
    # Idempotent default: don't re-download a clip we already have. To
    # force a re-fetch, `rm Forge/Tests/Corpus/clips/<id>.mp4` first.
    echo "  [$id] already on disk; skipping (rm the file to re-fetch)"
    return
  else
    if [[ "$source_url" == generated://* ]]; then
      local gen_id="${source_url#generated://}"
      # Skip-and-continue on a bad recipe, mirroring the download path —
      # otherwise `set -e` aborts the whole batch on one ffmpeg failure.
      local gen_script="generate_screencapture.sh"
      [[ "$category" == "signage" ]] && gen_script="generate_signage.sh"
      if ! "$SCRIPTS_DIR/$gen_script" "$gen_id" "$out"; then
        echo "  [$id] GENERATE FAILED ($gen_script $gen_id) — skipping" >&2
        rm -f "$out"
        return
      fi
    else
      local raw="$CLIPS_DIR/${id}.raw"
      echo "  [$id] downloading $source_url"
      # Don't bail the whole batch on a single 404 / DNS failure / mirror
      # outage — log the error against this clip and continue to the next.
      if ! curl -fsSL --connect-timeout 30 "$source_url" -o "$raw" 2>/dev/null; then
        echo "  [$id] DOWNLOAD FAILED — skipping (manifest stays unpopulated for this clip)" >&2
        rm -f "$raw"
        return
      fi

      # Transcode + apply per-clip degradation per notes.
      # `-nostdin` is mandatory: without it ffmpeg consumes the loop's input
      # stream and truncates the next clip's id (see the FD-9 note on the loop).
      case "$subcategory" in
        dvd-mpeg2)
          ffmpeg -nostdin -y -loglevel error -ss 0 -t 30 -i "$raw" -c:v mpeg2video \
            -pix_fmt yuv420p -b:v 4M -bf 2 -g 15 "$out"
          ;;
        interlaced)
          ffmpeg -nostdin -y -loglevel error -ss 0 -t 30 -i "$raw" -flags +ilme+ildct \
            -c:v libx264 -pix_fmt yuv420p -crf 22 -x264opts tff=1:interlaced=1 "$out"
          ;;
        broadcast-capture)
          ffmpeg -nostdin -y -loglevel error -ss 0 -t 30 -i "$raw" -c:v libx264 \
            -pix_fmt yuv420p -crf 28 -vf "noise=alls=8:allf=t" "$out"
          ;;
        *)
          # General default: trim to 30 s, h.264 CRF 22
          ffmpeg -nostdin -y -loglevel error -ss 0 -t 30 -i "$raw" -c:v libx264 \
            -pix_fmt yuv420p -crf 22 -an "$out"
          ;;
      esac
      rm -f "$raw"

      # Bail if the transcode produced no output (e.g. ffmpeg error on a
      # corrupt download, missing codec, etc.) — same skip-and-continue
      # behaviour as the download failure above.
      if [[ ! -f "$out" ]]; then
        echo "  [$id] TRANSCODE FAILED — skipping (no output file)" >&2
        return
      fi
    fi
  fi

  # Probe + hash.
  #
  # Each single-value probe is piped through `cut -d, -f1` to take only the
  # first CSV field. `ffprobe -of csv=p=0` is supposed to print just the value,
  # but for some streams (observed: mpeg2video) it appends a trailing field
  # separator, yielding "320," / "mpeg2video," — which then poisoned the
  # manifest's resolution/codec strings ("320,x240,"). Taking field 1 strips
  # the stray trailing comma; clean single values pass through unchanged. None
  # of these values (integers / codec name / fraction / duration float)
  # legitimately contains a comma, so this is lossless.
  local sha duration_s frame_rate codec width height
  sha="$(shasum -a 256 "$out" | awk '{print $1}')"
  duration_s="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out" | cut -d, -f1)"
  frame_rate="$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate \
    -of csv=p=0 "$out" | cut -d, -f1 | awk -F'/' '{ if ($2 > 0) printf "%.3f", $1/$2 ; else print $1 }')"
  codec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$out" | cut -d, -f1)"
  width="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$out" | cut -d, -f1)"
  height="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$out" | cut -d, -f1)"

  # Write back via jq
  local tmp; tmp="$(mktemp)"
  jq --arg id "$id" --arg sha "$sha" --argjson dur "$duration_s" \
     --argjson fps "$frame_rate" --arg codec "$codec" --arg res "${width}x${height}" \
     '(.clips[] | select(.id == $id)) |=
        (.sha256 = $sha | .duration_s = $dur | .frame_rate = $fps
         | .codec = $codec | .resolution = $res)' "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
  echo "  [$id] ok  sha=${sha:0:12}…  ${duration_s}s @${frame_rate}fps  ${codec}  ${width}x${height}"
}

# Whitelist of real clip ids — fetch_one's corruption guard matches against
# this. Computed once; the manifest is the single source of truth.
VALID_IDS="$(jq -r '.clips[].id' "$MANIFEST")"

# Iterate manifest entries via jq.
#
# The loop reads from a DEDICATED file descriptor (9), not stdin. This is the
# root-cause fix for the truncated-id corruption: `ffmpeg` reads stdin by
# default (to catch interactive 'q'/pause keys), so a plain `done < <(jq …)`
# loop has its input stream silently consumed by the ffmpeg child inside
# fetch_one — eating the front of the next clip's TSV line and handing `read`
# a leading-truncated id ("al-sports-01" for "general-sports-01"). Routing the
# loop through FD 9 isolates it from any stdin-consuming child (ffmpeg,
# ffprobe, curl). The `-nostdin` flags on the ffmpeg calls above are the
# belt-and-suspenders complement.
count_target=0
count_done=0
while IFS=$'\t' read -r id category subcategory source_url notes <&9; do
  count_target=$((count_target + 1))
  if [[ -n "$FILTER_ID" && "$id" != "$FILTER_ID" ]]; then continue; fi
  if [[ -n "$FILTER_CATEGORY" && "$category" != "$FILTER_CATEGORY" ]]; then continue; fi
  fetch_one "$id" "$category" "$subcategory" "$source_url" "$notes"
  count_done=$((count_done + 1))
done 9< <(jq -r '.clips[] | [.id, .category, .subcategory, .source_url, (.fetch_notes // "")] | @tsv' "$MANIFEST")

echo "Done. $count_done / $count_target clips processed."
