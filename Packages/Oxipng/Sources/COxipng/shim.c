/* COxipng is a thin C module exposing the oxipng_shim.h declarations; the
 * implementation lives in the vendored Rust staticlib (liboxipng_shim.a, built
 * by build.sh). This translation unit just gives SwiftPM a C source to compile
 * so the module is well-formed. */
#include "oxipng_shim.h"
