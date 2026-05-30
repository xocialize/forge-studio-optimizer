#!/usr/bin/env bash
#
# generate_signage.sh — Synthesize a single signage clip from a generator id.
#
# Pure ffmpeg synthesis. Outputs h.264 1080p mp4. Recipes are deterministic
# so re-running produces byte-identical files (modulo ffmpeg version), which
# keeps sha256 hashes stable in the manifest.
#
# Usage: generate_signage.sh <generator-id> <output.mp4>
#
# Supported generator ids match manifest entries:
#   signage_static_logo_01      static white logo over solid background
#   signage_static_logo_02      static colored logo over gradient
#   signage_dynamic_logo_01     rotating + scaling logo
#   signage_dynamic_logo_02     particle-reveal logo
#   signage_text_overlay_01     serif headline + body (30 s static)
#   signage_text_overlay_02     scrolling ticker + multi-line headline
#   signage_text_overlay_03     small-text menu board (12 pt) — stresses text-SR
#   signage_transition_01       cross-dissolve between 3 slides
#   signage_transition_02       wipe + slide transitions
#   signage_transition_03       push + zoom transitions

set -euo pipefail
GEN_ID="${1:?generator id required}"
OUT="${2:?output path required}"

# Use ffmpeg-full (keg-only) which ships --enable-libfreetype/libfontconfig/
# libharfbuzz and therefore supports the `drawtext` filter every signage recipe
# below uses. The default Homebrew `ffmpeg` formula (8.x in 2026) was split into
# minimal + full; the minimal bottle lacks drawtext. Install ffmpeg-full with
# `brew install ffmpeg-full`. We bind the binary to FFMPEG explicitly rather
# than relying on PATH, because some sandboxes scrub PATH for child processes.
if [[ -x /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ]]; then
  FFMPEG=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg
elif command -v ffmpeg >/dev/null 2>&1 && \
     ffmpeg -hide_banner -filters 2>&1 | grep -q " drawtext "; then
  FFMPEG="$(command -v ffmpeg)"
else
  cat >&2 <<'ERR'
ERROR: No ffmpeg with the `drawtext` filter is available.

Install Homebrew's full-feature ffmpeg formula:
    brew install ffmpeg-full

ffmpeg-full is keg-only and won't conflict with the standard `ffmpeg`
formula already on the system. The corpus scripts auto-discover it at
/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg.
ERR
  exit 64
fi

# Use a system font. Override via FORGE_SIGNAGE_FONT if needed.
FONT="${FORGE_SIGNAGE_FONT:-/System/Library/Fonts/Supplemental/Arial.ttf}"
FONT_SERIF="${FORGE_SIGNAGE_FONT_SERIF:-/System/Library/Fonts/Supplemental/Times New Roman.ttf}"

# Common encode flags — kept identical across recipes for reproducibility.
ENC=(-c:v libx264 -pix_fmt yuv420p -preset slow -crf 18 -profile:v high -level 4.1)

case "$GEN_ID" in
  signage_static_logo_01)
    "$FFMPEG" -nostdin -y -loglevel error -f lavfi -i "color=c=0x1a1a1a:s=1920x1080:r=30:d=30" \
      -vf "drawbox=x=760:y=440:w=400:h=200:c=0xffffff:t=fill,
           drawtext=fontfile=$FONT:text='MARQUEE':x=(w-tw)/2:y=(h-th)/2:fontsize=80:fontcolor=0x1a1a1a" \
      "${ENC[@]}" "$OUT"
    ;;
  signage_static_logo_02)
    "$FFMPEG" -nostdin -y -loglevel error -f lavfi -i "gradients=s=1920x1080:r=60:d=30:c0=0x0a3d62:c1=0x60a3bc" \
      -vf "drawbox=x=760:y=440:w=400:h=200:c=0xfdcb6e:t=fill,
           drawtext=fontfile=$FONT:text='FORGE':x=(w-tw)/2:y=(h-th)/2:fontsize=96:fontcolor=0x0a3d62" \
      "${ENC[@]}" "$OUT"
    ;;
  signage_dynamic_logo_01)
    # Rotating + pulsing-scale logo. Single -vf chain: draw the logo, scale it
    # by a time-varying factor, then rotate onto a fixed 1920x1080 canvas.
    #
    # Two prior bugs fixed here:
    #   1. Two separate `-vf` flags — ffmpeg keeps only the LAST, so the
    #      drawtext layer was silently dropped. Filters must be one chain.
    #   2. `scale=trunc(iw*…sin(2*PI*t/4)…)` without `eval=frame` — the scale
    #      filter evaluates its w/h in `init` mode by default, where the frame
    #      variable `t` is unavailable ("Expressions with frame variables
    #      'n','t','pos' are not valid in init eval_mode"). `eval=frame`
    #      re-evaluates per frame so `t` is in scope. The scale output size
    #      varies frame to frame (0.2×–0.8×), but the trailing rotate pins
    #      ow=1920:oh=1080 so the ENCODED stream stays constant-dimension.
    "$FFMPEG" -nostdin -y -loglevel error -f lavfi -i "color=c=0x1a1a1a:s=1920x1080:r=30:d=30" \
      -vf "drawtext=fontfile=$FONT:text='MARQUEE':x=(w-tw)/2:y=(h-th)/2:fontsize=120:fontcolor=white,
           scale=w='trunc(iw*(0.5+0.3*sin(2*PI*t/4)))':h='trunc(ih*(0.5+0.3*sin(2*PI*t/4)))':eval=frame,
           rotate='2*PI*t/8':c=0x1a1a1a:ow=1920:oh=1080" \
      "${ENC[@]}" "$OUT"
    ;;
  signage_dynamic_logo_02)
    # Particle reveal — radial mask growing over time
    "$FFMPEG" -nostdin -y -loglevel error -f lavfi -i "color=c=0x0a0a0a:s=1920x1080:r=30:d=30" \
      -vf "drawtext=fontfile=$FONT:text='REVEAL':x=(w-tw)/2:y=(h-th)/2:fontsize=160:fontcolor=white,
           geq='if(lte(hypot(X-W/2,Y-H/2),T*150),p(X,Y),16)':128:128" \
      "${ENC[@]}" "$OUT"
    ;;
  signage_text_overlay_01)
    "$FFMPEG" -nostdin -y -loglevel error -f lavfi -i "color=c=0xf5f3ee:s=1920x1080:r=30:d=30" \
      -vf "drawtext=fontfile=$FONT_SERIF:text='Welcome to Forge':x=(w-tw)/2:y=300:fontsize=96:fontcolor=0x1a1a1a,
           drawtext=fontfile=$FONT_SERIF:text='Convert once. Optimize intelligently.':x=(w-tw)/2:y=440:fontsize=44:fontcolor=0x3a3a3a,
           drawtext=fontfile=$FONT_SERIF:text='Play natively everywhere.':x=(w-tw)/2:y=500:fontsize=44:fontcolor=0x3a3a3a" \
      "${ENC[@]}" "$OUT"
    ;;
  signage_text_overlay_02)
    "$FFMPEG" -nostdin -y -loglevel error -f lavfi -i "color=c=0x111418:s=1920x1080:r=60:d=30" \
      -vf "drawtext=fontfile=$FONT:text='BREAKING NEWS':x=(w-tw)/2:y=120:fontsize=88:fontcolor=0xfff8dc,
           drawtext=fontfile=$FONT:text='Forge releases 2026 Q2 refresh':x=(w-tw)/2:y=260:fontsize=56:fontcolor=white,
           drawtext=fontfile=$FONT:text='NAFNet · SPANV2 · SigLIP2 · Real-ESRGAN MLX · Apple Silicon arm64':x=if(gte(t\,0)\,w-200*t\,w):y=950:fontsize=48:fontcolor=0xfdcb6e" \
      "${ENC[@]}" "$OUT"
    ;;
  signage_text_overlay_03)
    "$FFMPEG" -nostdin -y -loglevel error -f lavfi -i "color=c=0xffffff:s=1920x1080:r=30:d=30" \
      -vf "drawtext=fontfile=$FONT:text='MENU':x=80:y=80:fontsize=48:fontcolor=0x111111,
           drawtext=fontfile=$FONT:text='Espresso 3.50  Cappuccino 4.25  Latte 4.75  Macchiato 4.00':x=80:y=180:fontsize=24:fontcolor=0x222222,
           drawtext=fontfile=$FONT:text='Pour Over 5.00  Cold Brew 4.50  Drip Coffee 2.75  Americano 3.75':x=80:y=220:fontsize=24:fontcolor=0x222222,
           drawtext=fontfile=$FONT:text='Pastries - Croissant 3.50  Pain au Chocolat 4.00  Almond Tart 4.25':x=80:y=300:fontsize=24:fontcolor=0x222222,
           drawtext=fontfile=$FONT:text='Sandwiches - BLT 11.50  Caprese 12.00  Reuben 13.50  Banh Mi 12.75':x=80:y=340:fontsize=24:fontcolor=0x222222,
           drawtext=fontfile=$FONT:text='Hours - M-F 6a-7p Sa 7a-6p Su 8a-4p':x=80:y=940:fontsize=20:fontcolor=0x555555" \
      "${ENC[@]}" "$OUT"
    ;;
  signage_transition_01)
    # Cross-dissolve between 3 slides via xfade
    "$FFMPEG" -nostdin -y -loglevel error \
      -f lavfi -i "color=c=0xd64541:s=1920x1080:r=30:d=10" \
      -f lavfi -i "color=c=0x26ae60:s=1920x1080:r=30:d=10" \
      -f lavfi -i "color=c=0x2e9bda:s=1920x1080:r=30:d=10" \
      -filter_complex "[0:v][1:v]xfade=transition=fade:offset=9:duration=1[v01];
                       [v01][2:v]xfade=transition=fade:offset=19:duration=1,
                       drawtext=fontfile=$FONT:text='SLIDE\\: %{n}':x=(w-tw)/2:y=(h-th)/2:fontsize=160:fontcolor=white[v]" \
      -map "[v]" "${ENC[@]}" "$OUT"
    ;;
  signage_transition_02)
    "$FFMPEG" -nostdin -y -loglevel error \
      -f lavfi -i "color=c=0xfdcb6e:s=1920x1080:r=30:d=10" \
      -f lavfi -i "color=c=0x6c5ce7:s=1920x1080:r=30:d=10" \
      -f lavfi -i "color=c=0x00cec9:s=1920x1080:r=30:d=10" \
      -filter_complex "[0:v][1:v]xfade=transition=wiperight:offset=9:duration=1[v01];
                       [v01][2:v]xfade=transition=slideleft:offset=19:duration=1[v]" \
      -map "[v]" "${ENC[@]}" "$OUT"
    ;;
  signage_transition_03)
    "$FFMPEG" -nostdin -y -loglevel error \
      -f lavfi -i "color=c=0xc0392b:s=1920x1080:r=30:d=10" \
      -f lavfi -i "color=c=0x16a085:s=1920x1080:r=30:d=10" \
      -f lavfi -i "color=c=0x8e44ad:s=1920x1080:r=30:d=10" \
      -filter_complex "[0:v][1:v]xfade=transition=zoomin:offset=9:duration=1[v01];
                       [v01][2:v]xfade=transition=pixelize:offset=19:duration=1[v]" \
      -map "[v]" "${ENC[@]}" "$OUT"
    ;;
  *)
    echo "Unknown signage generator id: $GEN_ID" >&2
    exit 1
    ;;
esac
