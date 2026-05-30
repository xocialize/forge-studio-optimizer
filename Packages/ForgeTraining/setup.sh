#!/bin/bash
set -euo pipefail

# =============================================================================
# ForgeTraining setup.sh
# Bootstraps Python 3.12 venv + installs requirements for the offline NAFNet
# corpus generator. Idempotent: re-running upgrades pip + reinstalls deps,
# leaves an already-working venv intact.
#
# Per CLAUDE.md / Coding Plan §0, this rig is OFF-DEVICE only. No part of it
# is linked into Forge.app at runtime — it just produces tile pairs that get
# fed into Phase B.3's NAFNet trainer.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
REQUIREMENTS="$SCRIPT_DIR/requirements.txt"

# --- locate Python 3.12 ------------------------------------------------------
PYTHON_BIN=""
for candidate in python3.12 /opt/homebrew/opt/python@3.12/bin/python3.12 /opt/homebrew/bin/python3.12; do
    if command -v "$candidate" >/dev/null 2>&1; then
        PYTHON_BIN="$candidate"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "ERROR: Python 3.12 not found. Install via: brew install python@3.12" >&2
    exit 1
fi

echo "==> Using Python: $($PYTHON_BIN --version) at $(command -v $PYTHON_BIN)"

# --- locate ffmpeg-full ------------------------------------------------------
# Corpus generator prefers /opt/homebrew/opt/ffmpeg-full because it ships the
# full codec set (libaom for AV1, libx265 for HEVC, mpeg2video built-in).
FFMPEG_FULL="/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"
if [ -x "$FFMPEG_FULL" ]; then
    echo "==> Found ffmpeg-full: $FFMPEG_FULL"
    "$FFMPEG_FULL" -version | head -1
else
    echo "WARNING: $FFMPEG_FULL not found." >&2
    echo "         Install with: brew install ffmpeg-full (from homebrew-ffmpeg/ffmpeg tap)" >&2
    echo "         The CLI will fall back to plain 'ffmpeg' on PATH if libaom/libx265 are present." >&2
fi

# --- create / refresh venv ---------------------------------------------------
if [ -d "$VENV_DIR" ]; then
    echo "==> Reusing existing venv: $VENV_DIR"
else
    echo "==> Creating venv: $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

echo "==> Upgrading pip / setuptools / wheel"
python -m pip install --upgrade --quiet pip setuptools wheel

echo "==> Installing requirements from $REQUIREMENTS"
python -m pip install --quiet -r "$REQUIREMENTS"

# --- summary -----------------------------------------------------------------
echo ""
echo "================================================================"
echo "ForgeTraining venv ready."
echo "  Activate:        source $VENV_DIR/bin/activate"
echo "  Test:            python -m pytest $SCRIPT_DIR/Python/tests/ -v"
echo "  Run (corpus):    python $SCRIPT_DIR/Python/generate_multidegradation_corpus.py --help"
echo "  Run (efrlfn):    python $SCRIPT_DIR/Scripts/convert_efrlfn_to_mlx.py --help"
echo ""
echo "  Parity-test extra (PyTorch ↔ MLX EfRLFN test, Phase C.3):"
echo "      pip install -r $SCRIPT_DIR/requirements-parity.txt"
echo "================================================================"
python -c "import numpy, cv2, PIL, tqdm, mlx.core as mx, safetensors; \
print(f'numpy={numpy.__version__} cv2={cv2.__version__} Pillow={PIL.__version__} ' \
      f'tqdm={tqdm.__version__} mlx={mx.__version__} ' \
      f'safetensors={safetensors.__version__}')"
