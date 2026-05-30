#!/usr/bin/env bash
#
# generate_screencapture.sh — Synthesize a screen-capture-style test clip.
#
# Pure ffmpeg synthesis using lavfi inputs. Outputs h.264 1080p mp4.
# Deterministic; sha256 stable modulo ffmpeg version.
#
# Usage: generate_screencapture.sh <generator-id> <output.mp4>
#
# Supported ids:
#   screen_capture_demo_01     code-editor scrolling + cursor motion
#   screen_capture_demo_02     web-browser scrolling + tab switching

set -euo pipefail
GEN_ID="${1:?generator id required}"
OUT="${2:?output path required}"

# Bind ffmpeg explicitly to ffmpeg-full (drawtext, freetype). See
# generate_signage.sh for the rationale and remediation message.
if [[ -x /opt/homebrew/opt/ffmpeg-full/bin/ffmpeg ]]; then
  FFMPEG=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg
elif command -v ffmpeg >/dev/null 2>&1 && \
     ffmpeg -hide_banner -filters 2>&1 | grep -q " drawtext "; then
  FFMPEG="$(command -v ffmpeg)"
else
  echo "ERROR: No ffmpeg with drawtext available. Run \`brew install ffmpeg-full\`." >&2
  exit 64
fi

FONT="${FORGE_SCREENCAP_FONT:-/System/Library/Fonts/Supplemental/Courier New.ttf}"
ENC=(-c:v libx264 -pix_fmt yuv420p -preset slow -crf 18 -profile:v high -level 4.1)

case "$GEN_ID" in
  screen_capture_demo_01)
    # Code-editor look + scrolling lines + blinking cursor. The text strings
    # deliberately avoid `:`, `,`, `'`, `(`, `)`, and `\` — ffmpeg's drawtext
    # parser treats them as filter-graph option separators OR escape chars,
    # and embedding them inside text='...' is fragile across ffmpeg versions.
    # Plain ASCII alphanumeric + spaces + simple punctuation only. The intent
    # is to exercise the text-rendering encode path, not to produce
    # compileable code — the user-perceived effect is identical.
    "$FFMPEG" -nostdin -y -loglevel error -f lavfi -i "color=c=0x1e1e1e:s=1920x1080:r=60:d=30" \
      -vf "drawtext=fontfile=$FONT:text='func process buffer':x=80:y=80-mod(60*t\,1000):fontsize=22:fontcolor=0xd4d4d4,
           drawtext=fontfile=$FONT:text='    let denoised = NAFNet run buffer':x=80:y=120-mod(60*t\,1000):fontsize=22:fontcolor=0xd4d4d4,
           drawtext=fontfile=$FONT:text='    let upscaled = playback upscale denoised':x=80:y=160-mod(60*t\,1000):fontsize=22:fontcolor=0xd4d4d4,
           drawtext=fontfile=$FONT:text='    return upscaled':x=80:y=200-mod(60*t\,1000):fontsize=22:fontcolor=0xd4d4d4,
           drawtext=fontfile=$FONT:text='end':x=80:y=240-mod(60*t\,1000):fontsize=22:fontcolor=0xd4d4d4,
           drawbox=x=80+22*mod(t\,80):y=540:w=12:h=24:c=0xd4d4d4:t=fill" \
      "${ENC[@]}" "$OUT"
    ;;
  screen_capture_demo_02)
    # Browser-style: tab bar + scrolling content. The `Section N` text
    # previously used `%{eif\:floor(t/4)\:d}` which mixes filter-graph
    # colons with drawtext expansion colons — that's fragile too. Use a
    # plain static section title instead; the scroll motion is what
    # actually exercises the encoder path.
    "$FFMPEG" -nostdin -y -loglevel error -f lavfi -i "color=c=0xfafafa:s=1920x1080:r=60:d=30" \
      -vf "drawbox=x=0:y=0:w=1920:h=80:c=0xeeeeee:t=fill,
           drawbox=x=40:y=20:w=200:h=50:c=0xffffff:t=fill,
           drawtext=fontfile=$FONT:text='forge.app':x=60:y=35:fontsize=22:fontcolor=0x444444,
           drawbox=x=260:y=20:w=200:h=50:c=0xe0e0e0:t=fill,
           drawtext=fontfile=$FONT:text='docs':x=300:y=35:fontsize=22:fontcolor=0x555555,
           drawtext=fontfile=$FONT:text='Section Overview':x=80:y=200-mod(60*t\,1000):fontsize=48:fontcolor=0x111111,
           drawtext=fontfile=$FONT:text='Body text that scrolls continuously to simulate':x=80:y=280-mod(60*t\,1000):fontsize=24:fontcolor=0x333333,
           drawtext=fontfile=$FONT:text='a web-reading session with regular scroll motion':x=80:y=320-mod(60*t\,1000):fontsize=24:fontcolor=0x333333" \
      "${ENC[@]}" "$OUT"
    ;;
  *)
    echo "Unknown screencap generator id: $GEN_ID" >&2
    exit 1
    ;;
esac
