"""
verify_swift_load.py — Python proxy for the Swift weight-loader contract.

Loads a converted EfRLFN safetensors file and checks that the keys + shapes
match what ``ForgeUpscaler.EfRLFN``'s ``loadWeights(from:)`` extension will
expect at runtime (`update(verify: .noUnusedKeys)`).

This is **not** a Swift runtime test — that has to wait for Phase C.4 in
Xcode with MLX Metal. It is the strongest pre-flight check we can run from
the venv: the MLX-Python reference model has the same parameter hierarchy
as the Swift port (same @ModuleInfo names, same nesting), so passing here
means the Swift load will see the same key set.

Usage::

    python verify_swift_load.py \\
        --safetensors ../ForgeUpscaler/Sources/ForgeUpscaler/Resources/efrlfn_x4.safetensors \\
        --scale 4
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import mlx.core as mx
from mlx.utils import tree_flatten

# Bootstrap import path.
HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent.parent))  # Packages/ForgeTraining/

from Python.models.efrlfn_mlx import EfRLFN  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--safetensors", "-s", type=Path, required=True)
    p.add_argument("--scale", type=int, choices=(2, 4), required=True)
    args = p.parse_args(argv)

    if not args.safetensors.exists():
        print(f"ERROR: file not found: {args.safetensors}", file=sys.stderr)
        return 2

    # 1. Load file.
    loaded = mx.load(str(args.safetensors))
    print(f"loaded {len(loaded)} arrays from {args.safetensors.name}")

    # 2. Build the reference model and load weights into it. This is the
    # closest Python equivalent of the Swift call:
    #     try update(parameters: loaded, verify: .noUnusedKeys)
    model = EfRLFN(scale=args.scale)
    model.load_weights(list(loaded.items()))

    # 3. Verify no unused keys (file keys ⊆ model keys, and ideally equal).
    model_keys = {k for k, _ in tree_flatten(model.parameters())}
    file_keys = set(loaded.keys())

    file_only = file_keys - model_keys
    model_only = model_keys - file_keys

    if file_only:
        print("ERROR: file has keys the model does not expect:", file=sys.stderr)
        for k in sorted(file_only):
            print(f"  {k}", file=sys.stderr)
        return 3
    if model_only:
        print("ERROR: model expects keys not in the file:", file=sys.stderr)
        for k in sorted(model_only):
            print(f"  {k}", file=sys.stderr)
        return 4

    # 4. Shape check against the model's pre-load parameter shapes.
    # (`load_weights` already verified compatible shapes, but make this loud.)
    for k, ref in tree_flatten(model.parameters()):
        got = loaded[k]
        if tuple(ref.shape) != tuple(got.shape):
            print(
                f"ERROR: shape mismatch on {k}: model wants {ref.shape}, "
                f"file has {got.shape}",
                file=sys.stderr,
            )
            return 5

    # 5. Forward smoke test on a tiny tensor.
    x = mx.zeros((1, 8, 8, 3))
    y = model(x)
    mx.eval(y)
    expected_hw = 8 * args.scale
    if tuple(y.shape) != (1, expected_hw, expected_hw, 3):
        print(
            f"ERROR: forward output shape {y.shape} != "
            f"(1, {expected_hw}, {expected_hw}, 3)",
            file=sys.stderr,
        )
        return 6

    print(f"OK — {len(loaded)} keys match model, no unused keys, forward "
          f"shape {y.shape}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
