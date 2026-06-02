#ifndef OXIPNG_SHIM_H
#define OXIPNG_SHIM_H

#include <stdint.h>
#include <stdbool.h>

/// Losslessly optimize a PNG via oxipng (impl in the vendored Rust staticlib).
/// `level` 0..6 (higher = slower/smaller); `strip_safe` drops non-critical
/// metadata chunks. Returns 0 on success, <0 on error. Pixels are preserved
/// exactly — the "keep quality" guarantee.
int oxipng_optimize_file(const char *in_path, const char *out_path,
                         uint8_t level, bool strip_safe);

#endif /* OXIPNG_SHIM_H */
