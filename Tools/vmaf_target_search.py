#!/usr/bin/env python3
"""vmaf_target_search.py — Step 1 prototype (research roadmap / ADR-0013).

VMAF-targeted "auto-quality": instead of a fixed CRF, pick the per-clip quality
that hits a target VMAF via a fast **sample-encode** search (ab-av1 style) — a
few short probe encodes, not N full encodes. Encoder-agnostic prototype on
x264/libvmaf; the chosen-quality logic binds to the VideoToolbox quality knob at
ship time.

Demonstrates the per-title gain: a fixed CRF over-spends bits on easy content
(text/graphics → VMAF 99 when 95 would do) and under-delivers on hard content
(camera → VMAF 81). Targeting VMAF gives each clip *just enough* → smaller files
at a guaranteed quality.

    ./vmaf_target_search.py --target-vmaf 95 --fixed-crf 21 clipA.mp4 clipB.mp4 ...

NOT shipped — a measurement/prototype tool (ffmpeg+libx264+libvmaf, dev path per
ADR-0013). Reimplemented natively over VideoToolbox in Steps 1–2.
"""
from __future__ import annotations
import argparse, json, os, subprocess, tempfile, sys
from pathlib import Path

FFMPEG = os.environ.get("FFMPEG", "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
FFPROBE = os.environ.get("FFPROBE", "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe")


def run(args):
    subprocess.run(args, check=True, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def probe(path, key):
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0",
         "-show_entries", f"{key}", "-of", "default=nw=1:nk=1", str(path)],
        capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout.strip()
    return out.splitlines()[0] if out else ""


def duration(path):
    try:
        return float(probe(path, "format=duration"))
    except Exception:
        return 0.0


def make_sample_ref(src, tmp, n=3, dur=2.0):
    """Concat n short near-lossless segments (evenly spaced) → the VMAF reference."""
    d = duration(src)
    starts = [max(1.0, d * f - dur / 2) for f in ([0.5] if d < 8 else
              [(i + 1) / (n + 1) for i in range(n)])]
    parts = []
    for i, s in enumerate(starts):
        p = tmp / f"seg{i}.mp4"
        run([FFMPEG, "-nostdin", "-y", "-loglevel", "error", "-ss", f"{s:.2f}",
             "-t", f"{dur}", "-i", str(src),
             "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", "-an", str(p)])
        parts.append(p)
    ref = tmp / "sample_ref.mp4"
    lst = tmp / "list.txt"
    lst.write_text("".join(f"file '{p}'\n" for p in parts))
    run([FFMPEG, "-nostdin", "-y", "-loglevel", "error", "-f", "concat",
         "-safe", "0", "-i", str(lst), "-c", "copy", str(ref)])
    return ref


def vmaf(distorted, reference, tmp):
    log = tmp / "vmaf.json"
    subprocess.run(
        [FFMPEG, "-nostdin", "-y", "-loglevel", "error",
         "-i", str(distorted), "-i", str(reference),
         "-lavfi", f"[0:v][1:v]libvmaf=log_path={log}:log_fmt=json:n_threads=8",
         "-f", "null", "-"], check=True, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    d = json.loads(log.read_text())
    if "pooled_metrics" in d:
        return d["pooled_metrics"]["vmaf"]["mean"]
    return d["aggregate"]["VMAF_score"]  # older libvmaf


def encode_crf(src, crf, out):
    run([FFMPEG, "-nostdin", "-y", "-loglevel", "error", "-i", str(src),
         "-c:v", "libx264", "-preset", "medium", "-crf", str(crf),
         "-pix_fmt", "yuv420p", "-an", str(out)])


def size_mb(path):
    return os.path.getsize(path) / 1e6


def search_crf(ref, target, tmp, lo=16, hi=34):
    """Binary search CRF on the sample reference to hit target VMAF. Returns
    (crf, vmaf_at_crf, probes)."""
    probes = {}
    best = None
    while lo <= hi:
        mid = (lo + hi) // 2
        enc = tmp / f"probe_crf{mid}.mp4"
        encode_crf(ref, mid, enc)
        v = vmaf(enc, ref, tmp)
        probes[mid] = round(v, 2)
        enc.unlink(missing_ok=True)
        if v >= target:
            best = (mid, v)      # acceptable; try a higher CRF (smaller file)
            lo = mid + 1
        else:
            hi = mid - 1
    if best is None:             # even the lowest CRF missed target → use lo bound
        best = (max(16, lo), probes.get(max(16, lo), 0))
    return best[0], best[1], probes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clips", nargs="+", type=Path)
    ap.add_argument("--target-vmaf", type=float, default=95.0)
    ap.add_argument("--fixed-crf", type=int, default=21, help="baseline to beat")
    ap.add_argument("--full-encode", action="store_true",
                    help="confirm with a full-clip encode of chosen + fixed CRF")
    args = ap.parse_args()

    print(f"VMAF-target search — target={args.target_vmaf}, baseline=fixed CRF {args.fixed_crf}\n")
    hdr = f"{'clip':22s} {'chosenCRF':>9s} {'sampleVMAF':>10s}"
    if args.full_encode:
        hdr += f" {'targMB':>7s} {'targVMAF':>8s} {'fixedMB':>7s} {'fixedVMAF':>9s} {'savings':>8s}"
    print(hdr)
    tot_t = tot_f = 0.0
    for clip in args.clips:
        if not clip.exists():
            print(f"{clip.name[:22]:22s}  MISSING"); continue
        with tempfile.TemporaryDirectory(prefix="vts_") as td:
            tmp = Path(td)
            ref = make_sample_ref(clip, tmp)
            crf, v, probes = search_crf(ref, args.target_vmaf, tmp)
            row = f"{clip.stem[:22]:22s} {crf:9d} {v:10.2f}"
            if args.full_encode:
                te = tmp / "targ.mp4"; encode_crf(clip, crf, te)
                fe = tmp / "fix.mp4"; encode_crf(clip, args.fixed_crf, fe)
                tmb, fmb = size_mb(te), size_mb(fe)
                tv = vmaf(te, clip, tmp); fv = vmaf(fe, clip, tmp)
                sav = (1 - tmb / fmb) * 100 if fmb else 0
                tot_t += tmb; tot_f += fmb
                row += f" {tmb:7.2f} {tv:8.2f} {fmb:7.2f} {fv:9.2f} {sav:7.1f}%"
            print(row)
    if args.full_encode and tot_f:
        print(f"\n  TOTAL: targeted {tot_t:.1f} MB vs fixed {tot_f:.1f} MB "
              f"→ {(1 - tot_t / tot_f) * 100:.1f}% smaller at a guaranteed "
              f"VMAF≥{args.target_vmaf:.0f}")


if __name__ == "__main__":
    sys.exit(main())
