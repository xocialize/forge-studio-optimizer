#!/usr/bin/env python3
"""vmaf_target_search.py — Step 1 prototype (research roadmap / ADR-0013).

VMAF-targeted "auto-quality": instead of a fixed quality, pick the per-clip
quality that hits a target VMAF via a fast **sample-encode** search (ab-av1
style) — a few short probe encodes, not N full encodes.

Encoder-agnostic. Supports the SHIP encoder (Apple VideoToolbox HEVC, ADR-0013;
constant-quality via -q:v = kVTCompressionPropertyKey_Quality) and the
measurement encoder (x264 CRF). The chosen-quality logic binds to the
VideoToolbox quality knob at ship.

    ./vmaf_target_search.py --encoder hevc_videotoolbox --target-vmaf 95 clipA.mp4 ...
    ./vmaf_target_search.py --encoder libx264 --target-vmaf 95 --fixed 21 clipA.mp4 ...

NOT shipped — a dev/measurement tool (ffmpeg path per ADR-0013).
"""
from __future__ import annotations
import argparse, json, os, subprocess, tempfile, sys
from pathlib import Path

FFMPEG = os.environ.get("FFMPEG", "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
FFPROBE = os.environ.get("FFPROBE", "/opt/homebrew/opt/ffmpeg-full/bin/ffprobe")

# Per-encoder: how to encode at a quality param, the search range, and whether
# VMAF RISES with the param (VT q:v: yes; x264 CRF: no). "fixed" is the flat
# baseline-to-beat for that encoder.
ENCODERS = {
    "hevc_videotoolbox": dict(
        args=lambda p: ["-c:v", "hevc_videotoolbox", "-q:v", str(p), "-tag:v", "hvc1"],
        lo=30, hi=90, vmaf_rises_with_param=True, fixed=55, label="VT-HEVC q:v"),
    "h264_videotoolbox": dict(
        args=lambda p: ["-c:v", "h264_videotoolbox", "-q:v", str(p)],
        lo=30, hi=90, vmaf_rises_with_param=True, fixed=55, label="VT-H264 q:v"),
    "libx264": dict(
        args=lambda p: ["-c:v", "libx264", "-preset", "medium", "-crf", str(p)],
        lo=16, hi=34, vmaf_rises_with_param=False, fixed=21, label="x264 CRF"),
}


def run(args):
    subprocess.run(args, check=True, stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def probe(path, key):
    out = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries", key,
         "-of", "default=nw=1:nk=1", str(path)],
        capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout.strip()
    return out.splitlines()[0] if out else ""


def duration(path):
    try:
        return float(probe(path, "format=duration"))
    except Exception:
        return 0.0


def make_sample_ref(src, tmp, n=3, dur=2.0):
    """Concat n short near-lossless segments → encoder-independent VMAF reference."""
    d = duration(src)
    starts = ([max(1.0, d * 0.5 - dur / 2)] if d < 8
              else [d * (i + 1) / (n + 1) for i in range(n)])
    parts = []
    for i, s in enumerate(starts):
        p = tmp / f"seg{i}.mp4"
        run([FFMPEG, "-nostdin", "-y", "-loglevel", "error", "-ss", f"{s:.2f}",
             "-t", f"{dur}", "-i", str(src),
             "-c:v", "libx264", "-crf", "12", "-pix_fmt", "yuv420p", "-an", str(p)])
        parts.append(p)
    ref, lst = tmp / "sample_ref.mp4", tmp / "list.txt"
    lst.write_text("".join(f"file '{p}'\n" for p in parts))
    run([FFMPEG, "-nostdin", "-y", "-loglevel", "error", "-f", "concat",
         "-safe", "0", "-i", str(lst), "-c", "copy", str(ref)])
    return ref


def encode(src, param, out, enc):
    run([FFMPEG, "-nostdin", "-y", "-loglevel", "error", "-i", str(src),
         *ENCODERS[enc]["args"](param), "-pix_fmt", "yuv420p", "-an", str(out)])


def vmaf(distorted, reference, tmp):
    log = tmp / "vmaf.json"
    subprocess.run(
        [FFMPEG, "-nostdin", "-y", "-loglevel", "error",
         "-i", str(distorted), "-i", str(reference),
         "-lavfi", f"[0:v][1:v]libvmaf=log_path={log}:log_fmt=json:n_threads=8",
         "-f", "null", "-"], check=True, stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    d = json.loads(log.read_text())
    return d["pooled_metrics"]["vmaf"]["mean"] if "pooled_metrics" in d \
        else d["aggregate"]["VMAF_score"]


def size_mb(path):
    return os.path.getsize(path) / 1e6


def search(ref, target, enc, tmp):
    """Binary-search the quality param for the SMALLEST file with VMAF>=target."""
    cfg = ENCODERS[enc]
    lo, hi, rises = cfg["lo"], cfg["hi"], cfg["vmaf_rises_with_param"]
    best, probes = None, {}
    while lo <= hi:
        mid = (lo + hi) // 2
        enc_f = tmp / f"probe_{mid}.mp4"
        encode(ref, mid, enc_f, enc)
        v = vmaf(enc_f, ref, tmp); probes[mid] = round(v, 2)
        enc_f.unlink(missing_ok=True)
        ok = v >= target
        if ok:
            best = (mid, v)
            # smaller file is: lower param if VMAF rises with param, else higher
            if rises: hi = mid - 1
            else:     lo = mid + 1
        else:
            if rises: lo = mid + 1
            else:     hi = mid - 1
    if best is None:                      # nothing hit target → use highest-quality bound
        b = cfg["hi"] if rises else cfg["lo"]
        best = (b, probes.get(b, 0))
    return best[0], best[1]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("clips", nargs="+", type=Path)
    ap.add_argument("--encoder", choices=list(ENCODERS), default="hevc_videotoolbox")
    ap.add_argument("--target-vmaf", type=float, default=95.0)
    ap.add_argument("--fixed", type=int, default=None, help="flat baseline param to beat")
    ap.add_argument("--full-encode", action="store_true")
    args = ap.parse_args()
    cfg = ENCODERS[args.encoder]
    rises = cfg["vmaf_rises_with_param"]

    # Pass 1: per-clip optimal quality (just hits the VMAF floor).
    print(f"encoder={args.encoder} ({cfg['label']}) · target VMAF={args.target_vmaf}\n")
    print(f"{'clip':22s} {'chosen':>7s} {'sampVMAF':>8s}")
    chosen = {}
    for clip in args.clips:
        if not clip.exists():
            print(f"{clip.name[:22]:22s} MISSING"); continue
        with tempfile.TemporaryDirectory(prefix="vts_") as td:
            tmp = Path(td)
            q, v = search(make_sample_ref(clip, tmp), args.target_vmaf, args.encoder, tmp)
            chosen[clip] = q
            print(f"{clip.stem[:22]:22s} {q:7d} {v:8.2f}")
    if not args.full_encode or not chosen:
        return

    # The FAIR fixed-ladder baseline: the single flat quality that makes the
    # HARDEST clip hit the floor (max q:v for VT, min CRF for x264). A fixed
    # ladder must be set conservatively for the worst content; per-title saves
    # by not over-serving the easy clips. (Override with --fixed.)
    base = args.fixed if args.fixed is not None else (
        max(chosen.values()) if rises else min(chosen.values()))
    print(f"\nfloor-guaranteeing flat baseline: {cfg['label']} {base}  "
          f"(set by the hardest clip)\n")
    print(f"{'clip':22s} {'targMB':>7s} {'targVMAF':>8s} {'fixedMB':>7s} {'fixedVMAF':>9s} {'savings':>8s}")
    tt = tf = 0.0
    for clip in args.clips:
        if clip not in chosen:
            continue
        with tempfile.TemporaryDirectory(prefix="vtf_") as td:
            tmp = Path(td)
            te = tmp / "t.mp4"; encode(clip, chosen[clip], te, args.encoder)
            fe = tmp / "f.mp4"; encode(clip, base, fe, args.encoder)
            tmb, fmb = size_mb(te), size_mb(fe)
            tv, fv = vmaf(te, clip, tmp), vmaf(fe, clip, tmp)
            sav = (1 - tmb / fmb) * 100 if fmb else 0
            tt += tmb; tf += fmb
            print(f"{clip.stem[:22]:22s} {tmb:7.2f} {tv:8.2f} {fmb:7.2f} {fv:9.2f} {sav:7.1f}%")
    if tf:
        print(f"\n  TOTAL: per-title {tt:.1f} MB vs floor-flat {tf:.1f} MB → "
              f"{(1 - tt / tf) * 100:.1f}% smaller at guaranteed VMAF>={args.target_vmaf:.0f}")


if __name__ == "__main__":
    sys.exit(main())
