//! Minimal C-ABI shim over oxipng (lossless PNG optimization) for ImageBridge.
//! Lossless = pixels are mathematically preserved (the "pngcrush but keeps
//! quality" guarantee). `panic = "abort"` (Cargo.toml) ⇒ no unwind across FFI.

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;

/// Optimize `in_path` and write the result to `out_path`.
/// - `level`: oxipng preset 0..=6 (higher = slower / smaller).
/// - `strip_safe`: drop non-critical metadata chunks (oxipng `--strip safe`).
/// Returns 0 on success, <0 on error (-1 bad args, -2 optimize failed).
#[no_mangle]
pub extern "C" fn oxipng_optimize_file(
    in_path: *const c_char,
    out_path: *const c_char,
    level: u8,
    strip_safe: bool,
) -> c_int {
    if in_path.is_null() || out_path.is_null() {
        return -1;
    }
    let inp = match unsafe { CStr::from_ptr(in_path) }.to_str() {
        Ok(s) => PathBuf::from(s),
        Err(_) => return -1,
    };
    let outp = match unsafe { CStr::from_ptr(out_path) }.to_str() {
        Ok(s) => PathBuf::from(s),
        Err(_) => return -1,
    };

    let mut opts = oxipng::Options::from_preset(level.min(6));
    if strip_safe {
        opts.strip = oxipng::StripChunks::Safe;
    }

    let infile = oxipng::InFile::Path(inp);
    let outfile = oxipng::OutFile::Path {
        path: Some(outp),
        preserve_attrs: false,
    };

    match oxipng::optimize(&infile, &outfile, &opts) {
        Ok(()) => 0,
        Err(_) => -2,
    }
}
