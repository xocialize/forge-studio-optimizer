// FFmpegXC shim — required for SPM to treat this as a C target.
// All actual code lives in the pre-built static libraries.
// Intentionally empty — this file exists only so SPM treats this as a C target.
// All FFmpeg code is in pre-built static libraries.
// Headers are exposed via publicHeadersPath = "include".
int _ffmpegxc_shim_unused = 0;
