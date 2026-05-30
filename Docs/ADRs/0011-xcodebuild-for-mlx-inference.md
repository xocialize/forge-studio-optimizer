# ADR 0011 — Build runnable MLX binaries with xcodebuild; resources per-file

**Date**: 2026-05-30
**Status**: Accepted
**Relates to**: [ADR-0001](0001-forge-2026-q2-refresh-kickoff.md), the relocation (#44), mlx-porting skill §"SPM CLI cannot compile Metal shaders"

---

## Context

Running the first MLX-inference job in the relocated `forge-studio-optimizer`
repo — an SR benchmark over the real-signage eval clips — failed twice in a row,
each a build/packaging gap that the old Forge repo never surfaced (it built via
xcodebuild). Both must be fixed for *any* runnable MLX binary here (the benchmark
runner now, B.5 NAFNet integration next).

**1. Metallib.** `swift build -c release` (the command our CLAUDE.md used)
compiles the Swift fine but **never compiles mlx-swift's Metal kernels into
`default.metallib`**. The binary then dies at first GPU op:

> `MLX error: Failed to load the default metallib. library not found`

mlx-swift's `Package.swift` sets `METAL_PATH = "default.metallib"` and ships only
`.metal` kernel *sources* — Xcode's Metal build phase compiles them; the SwiftPM
CLI does not. (The Coding Plan already said "Build tool is xcodebuild"; the
relocated repo had only ever been `swift build`'d to check compilation.)

**2. Resource nesting.** With the metallib fixed, the SR weights failed to load:

> `PlaybackTier weights not found in bundle: realesr_general_x4`

`ForgeUpscaler/Package.swift` declared `resources: [.copy("Resources")]`, which
copies the whole folder → `…ForgeUpscaler.bundle/Contents/Resources/Resources/<files>`
(doubly nested under xcodebuild's macOS bundle layout). But the code resolves
weights with `Bundle.module.url(forResource:withExtension:)` and **no
subdirectory**, which only searches the resource root. So *every* weight +
`.mlpackage` lookup missed.

## Decision

1. **Build any runnable MLX-inference binary with `xcodebuild`, not `swift build`.**
   `swift build` is acceptable only for non-MLX compile checks. Canonical:
   ```
   xcodebuild build -scheme forge-benchmark-runner -configuration Release \
       -destination 'platform=macOS' -derivedDataPath .xcode-build
   # binary:   .xcode-build/Build/Products/Release/forge-benchmark-runner
   # metallib: …/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib (sibling)
   ```
   Tests likewise: `xcodebuild test -scheme ForgeOptimizer-Package`.

2. **Declare bundled resources per-file, not `.copy("Resources")`.** Each
   `.copy("Resources/<file>")` lands the file at the bundle resource root where
   `Bundle.module.url(forResource:withExtension:)` finds it. `.process("Resources")`
   is rejected because it compiles/mangles the `.mlpackage` directories.

## Consequences

- `ForgeUpscaler/Package.swift` switched to 8 per-file `.copy` entries
  (5 safetensors + 2 `.mlpackage` + MODELS.md). **VALIDATED 2026-05-30** by a
  clean xcodebuild: all 5 safetensors + both `.mlpackage` dirs land flat at the
  bundle resource root, no `Resources/Resources/` nesting → `Bundle.module`
  lookups resolve with no hack. (The first SR run had used a one-shot bundle
  hack — lifting the nested files to the root — on gitignored `.xcode-build/`
  output; no longer needed.)
- CLAUDE.md + README build sections corrected (`swift build` → `xcodebuild`).
- `.xcode-build/` is a DerivedData dir — gitignored (covered by `.build`/Derived
  patterns; add explicitly if not).
- B.5 (wire NAFNet) and all future benchmark runs use the xcodebuild binary.
  NAFNet's own weights, when vendored into `ForgeOptimizer/.../Resources/`, must
  follow the same per-file `.copy` rule.

## References

- mlx-porting skill → `references/repo-layout.md` "SPM CLI cannot compile Metal
  shaders" (the documented escape hatch: build via xcodebuild; bundle-copy +
  rename as last resort).
- Failure logs: `/tmp/xcodebuild_runner.log`, `/tmp/sr_run.log` (local).
