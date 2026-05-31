#!/usr/bin/env python3
"""
ADR-0014 compression gate measurement.

Runs Step 1 (per-title VMAF-target, forge-quality-target) across a HIGH-BITRATE
corpus subset, then compares the per-title-targeted encodes to a single
floor-guaranteeing FLAT-quality baseline (Q_flat = the max per-clip quality, which
guarantees VMAF >= floor on every clip). The gate metric is how much smaller
per-title targeting is than that flat baseline.

This exists because "savings vs source" is unmeasurable on already-compressed
clips (ADR-0014); the honest product claim is "smaller at a guaranteed quality
vs a one-size-fits-all flat encode" on true masters.

Usage:
  quality_target_gate.py <forge-quality-target binary> <clips dir> [--target 95]
      [--max-frames 120] [--min-savings 30] [--clips a.mp4,b.mp4,...]
"""
import argparse, json, os, subprocess, sys

# Default high-bitrate (>=8 Mbps) progressive masters in the royalty-free corpus.
DEFAULT_SUBSET = [
    "general-sports-01.mp4",       # 41 Mbps
    "general-sports-02.mp4",       # 11 Mbps
    "general-talkinghead-01.mp4",  # 8.9 Mbps
]

def run(binary, clip_path, target, max_frames, fixed=None):
    args = [binary, "--input", clip_path, "--target", str(target),
            "--max-frames", str(max_frames), "--json"]
    if fixed is not None:
        args += ["--fixed", f"{fixed:.3f}"]
    p = subprocess.run(args, capture_output=True, text=True)
    for line in p.stdout.splitlines():
        if line.startswith("JSON "):
            return json.loads(line[len("JSON "):])
    raise RuntimeError(f"no JSON for {clip_path}\nstdout:\n{p.stdout[-400:]}\nstderr:\n{p.stderr[-400:]}")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary"); ap.add_argument("clips_dir")
    ap.add_argument("--target", type=float, default=95.0)
    ap.add_argument("--slack", type=float, default=0.5)
    ap.add_argument("--max-frames", type=int, default=120)
    ap.add_argument("--min-savings", type=float, default=30.0)
    ap.add_argument("--clips", default=",".join(DEFAULT_SUBSET))
    a = ap.parse_args()
    subset = [c for c in a.clips.split(",") if c]

    print(f"ADR-0014 gate — target VMAF {a.target}, {len(subset)} high-bitrate clips, "
          f"{a.max_frames}-frame samples\n")

    # Phase 1 — per-title VMAF-target each clip.
    targeted = {}
    for c in subset:
        r = run(a.binary, os.path.join(a.clips_dir, c), a.target, a.max_frames)
        targeted[c] = r
        print(f"  target  {c:32s} q={r['quality']:.3f}  VMAF={r['achievedVMAF']:.2f}  "
              f"{r['targetedBytes']/1e6:.2f} MB")

    q_flat = max(r["quality"] for r in targeted.values())
    print(f"\nflat baseline quality (max per-clip q, guarantees the floor): {q_flat:.3f}\n")

    # Phase 2 — flat floor-guaranteeing baseline at Q_flat.
    flat = {}
    for c in subset:
        r = run(a.binary, os.path.join(a.clips_dir, c), a.target, a.max_frames, fixed=q_flat)
        flat[c] = r
        print(f"  flat    {c:32s} q={q_flat:.3f}  VMAF={r['achievedVMAF']:.2f}  "
              f"{r['targetedBytes']/1e6:.2f} MB")

    sum_t = sum(r["targetedBytes"] for r in targeted.values())
    sum_b = sum(r["targetedBytes"] for r in flat.values())
    savings = (1 - sum_t / sum_b) * 100 if sum_b else 0.0
    floor_ok = all(r["achievedVMAF"] >= a.target - a.slack for r in targeted.values())
    worst_vmaf = min(r["achievedVMAF"] for r in targeted.values())

    print("\n── ADR-0014 gate ─────────────────────────────────────")
    print(f"per-title targeted total : {sum_t/1e6:.2f} MB")
    print(f"flat baseline total      : {sum_b/1e6:.2f} MB")
    print(f"compression_quality_target : {savings:.1f}% smaller than flat "
          f"(gate: >= {a.min_savings:.0f}%)  -> {'PASS' if savings >= a.min_savings else 'FAIL'}")
    print(f"vmaf_target_floor          : worst {worst_vmaf:.2f} (>= {a.target - a.slack:.1f})"
          f"  -> {'PASS' if floor_ok else 'FAIL'}")
    ok = savings >= a.min_savings and floor_ok
    print(f"\nGATE: {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
