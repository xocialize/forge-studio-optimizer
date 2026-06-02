#!/bin/bash
# Build the oxipng C-ABI shim (Rust staticlib) → vendored .a for the COxipng target.
# The .a is gitignored (built locally, like FFmpegXC's libs); the header + Swift
# wrapper are committed. Requires the Rust toolchain (rustup).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$HOME/.cargo/env" 2>/dev/null || true

command -v cargo >/dev/null || { echo "cargo not found — install Rust: https://rustup.rs"; exit 1; }

echo "=== building oxipng_shim (release staticlib) ==="
( cd "$DIR/rust" && cargo build --release )

mkdir -p "$DIR/Sources/COxipng/lib"
cp "$DIR/rust/target/release/liboxipng_shim.a" "$DIR/Sources/COxipng/lib/liboxipng_shim.a"
echo "vendored → Sources/COxipng/lib/liboxipng_shim.a  ($(du -h "$DIR/Sources/COxipng/lib/liboxipng_shim.a" | cut -f1))"
