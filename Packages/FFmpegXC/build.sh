#!/bin/bash
set -euo pipefail

# =============================================================================
# FFmpegXC Build Script
# Builds FFmpeg + third-party libs as static libraries for macOS arm64
# Output: Sources/FFmpegXC/include/ and Sources/FFmpegXC/lib/
# =============================================================================

# Ensure Homebrew is in PATH (Apple Silicon default location)
if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRATCH_DIR="$SCRIPT_DIR/scratch"
INSTALL_DIR="$SCRATCH_DIR/install"
DEPS_DIR="$SCRATCH_DIR/deps"
OUTPUT_INCLUDE="$SCRIPT_DIR/Sources/FFmpegXC/include"
OUTPUT_LIB="$SCRIPT_DIR/Sources/FFmpegXC/lib"

# Versions
FFMPEG_VERSION="7.1.1"
DAV1D_VERSION="1.5.1"
OPUS_VERSION="1.5.2"
LIBVPX_TAG="v1.14.1"
# SVT-AV1 (BSD-2 + AOM patent grant) — in-process AV1 ENCODE (#58, ADR-0017 Phase B).
# Pinned to 2.3.0: the last v2-API release vanilla FFmpeg 7.1.1's libsvtav1 wrapper
# compiles against (SVT-AV1 3.x changed the API). Encoder-only, static.
SVT_AV1_VERSION="2.3.0"

# Build settings
ARCH="arm64"
DEPLOYMENT_TARGET="13.0"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx -f clang)"
NCPU="$(sysctl -n hw.ncpu)"

COMMON_CFLAGS="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $SDK_PATH"
COMMON_LDFLAGS="-arch $ARCH -mmacosx-version-min=$DEPLOYMENT_TARGET -isysroot $SDK_PATH"

echo "============================================"
echo "FFmpegXC Build Script"
echo "============================================"
echo "FFmpeg:    $FFMPEG_VERSION"
echo "dav1d:     $DAV1D_VERSION"
echo "libvpx:    $LIBVPX_TAG"
echo "opus:      $OPUS_VERSION"
echo "Arch:      $ARCH"
echo "SDK:       $SDK_PATH"
echo "Threads:   $NCPU"
echo "============================================"
echo ""

# Check dependencies
check_dep() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: $1 not found. Install via: brew install $2"
        exit 1
    fi
}

check_dep nasm nasm
check_dep pkg-config pkg-config
check_dep cmake cmake
check_dep meson meson
check_dep ninja ninja

mkdir -p "$SCRATCH_DIR" "$INSTALL_DIR" "$DEPS_DIR/lib" "$DEPS_DIR/include"

# =============================================================================
# Step 1: Download sources
# =============================================================================

download_source() {
    local name="$1"
    local url="$2"
    local dir="$3"

    if [ -d "$SCRATCH_DIR/$dir" ]; then
        echo "[$name] Source already exists, skipping download"
        return 0
    fi

    echo "[$name] Downloading..."
    cd "$SCRATCH_DIR"

    if [[ "$url" == *.tar.xz ]]; then
        curl -L -o "$name.tar.xz" "$url"
        tar xf "$name.tar.xz"
        rm "$name.tar.xz"
    elif [[ "$url" == *.tar.gz ]]; then
        curl -L -o "$name.tar.gz" "$url"
        tar xf "$name.tar.gz"
        rm "$name.tar.gz"
    elif [[ "$url" == *.git ]]; then
        git clone --depth 1 --branch "$4" "$url" "$dir"
    fi

    echo "[$name] Downloaded to $SCRATCH_DIR/$dir"
}

echo "=== Downloading sources ==="
download_source "ffmpeg" \
    "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
    "ffmpeg-${FFMPEG_VERSION}"

download_source "dav1d" \
    "https://code.videolan.org/videolan/dav1d/-/archive/${DAV1D_VERSION}/dav1d-${DAV1D_VERSION}.tar.gz" \
    "dav1d-${DAV1D_VERSION}"

download_source "libvpx" \
    "https://chromium.googlesource.com/webm/libvpx.git" \
    "libvpx" \
    "$LIBVPX_TAG"

download_source "opus" \
    "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" \
    "opus-${OPUS_VERSION}"

download_source "svt-av1" \
    "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${SVT_AV1_VERSION}/SVT-AV1-v${SVT_AV1_VERSION}.tar.gz" \
    "SVT-AV1-v${SVT_AV1_VERSION}"

echo ""

# =============================================================================
# Step 2: Build libopus (simplest, no weird build system)
# =============================================================================

echo "=== Building libopus ==="
cd "$SCRATCH_DIR/opus-${OPUS_VERSION}"

if [ ! -f "$DEPS_DIR/lib/libopus.a" ]; then
    make clean 2>/dev/null || true

    ./configure \
        --host=aarch64-apple-darwin \
        --prefix="$DEPS_DIR" \
        --enable-static \
        --disable-shared \
        --disable-doc \
        --disable-extra-programs \
        CFLAGS="$COMMON_CFLAGS" \
        LDFLAGS="$COMMON_LDFLAGS"

    make -j"$NCPU"
    make install
    echo "[opus] Build complete"
else
    echo "[opus] Already built, skipping"
fi

echo ""

# =============================================================================
# Step 3: Build libdav1d (meson + ninja)
# =============================================================================

echo "=== Building libdav1d ==="
cd "$SCRATCH_DIR/dav1d-${DAV1D_VERSION}"

if [ ! -f "$DEPS_DIR/lib/libdav1d.a" ]; then
    # Create meson cross file for macOS arm64
    cat > "$SCRATCH_DIR/macos-arm64-cross.ini" << CROSSEOF
[binaries]
c = '$(xcrun --sdk macosx -f clang)'
strip = '$(xcrun --sdk macosx -f strip)'
ar = '$(xcrun --sdk macosx -f ar)'

[properties]
c_args = ['-arch', 'arm64', '-mmacosx-version-min=${DEPLOYMENT_TARGET}', '-isysroot', '${SDK_PATH}']
c_link_args = ['-arch', 'arm64', '-mmacosx-version-min=${DEPLOYMENT_TARGET}', '-isysroot', '${SDK_PATH}']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
CROSSEOF

    rm -rf build
    meson setup build \
        --prefix="$DEPS_DIR" \
        --default-library=static \
        --buildtype=release \
        -Denable_tools=false \
        -Denable_tests=false \
        -Denable_examples=false \
        --cross-file="$SCRATCH_DIR/macos-arm64-cross.ini"

    ninja -C build
    ninja -C build install
    echo "[dav1d] Build complete"
else
    echo "[dav1d] Already built, skipping"
fi

echo ""

# =============================================================================
# Step 4: Build libvpx
# =============================================================================

echo "=== Building libvpx ==="
cd "$SCRATCH_DIR/libvpx"

if [ ! -f "$DEPS_DIR/lib/libvpx.a" ]; then
    make distclean 2>/dev/null || true

    # libvpx's arm64-darwin-gcc target defaults to iOS SDK.
    # We override by setting CC/CXX/LD to use the macOS SDK explicitly,
    # and pass macOS deployment target via extra-cflags.
    CC="$CC -isysroot $SDK_PATH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
    CXX="$(xcrun --sdk macosx -f clang++) -isysroot $SDK_PATH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
    LD="$CC -isysroot $SDK_PATH -mmacosx-version-min=$DEPLOYMENT_TARGET" \
    ./configure \
        --prefix="$DEPS_DIR" \
        --target=arm64-darwin-gcc \
        --enable-static \
        --disable-shared \
        --enable-pic \
        --disable-examples \
        --disable-tools \
        --disable-docs \
        --disable-unit-tests \
        --enable-vp8-decoder \
        --enable-vp9-decoder \
        --enable-vp8-encoder \
        --enable-vp9-encoder

    # The configure may still inject iOS flags. Patch them out.
    # Pin to whatever macOS SDK xcrun reports rather than hardcoding a version —
    # SDK bumps (e.g. 26.4 → 26.5) otherwise leave the sysroot pointing at a
    # nonexistent path and the build fails with "stdlib.h file not found".
    SDK_BASENAME="$(basename "$SDK_PATH")"
    for mk in libs-arm64-darwin-gcc.mk Makefile; do
        if [ -f "$mk" ] && grep -q "iPhoneOS\|iphoneos-version-min" "$mk" 2>/dev/null; then
            sed -i '' "s|-miphoneos-version-min=[0-9.]*|-mmacosx-version-min=$DEPLOYMENT_TARGET|g" "$mk"
            sed -i '' "s|iPhoneOS.platform/Developer/SDKs/iPhoneOS[0-9.]*.sdk|MacOSX.platform/Developer/SDKs/$SDK_BASENAME|g" "$mk"
            sed -i '' "s|-fembed-bitcode||g" "$mk"
            echo "[vpx] Patched $mk for macOS SDK ($SDK_BASENAME)"
        fi
    done

    make -j"$NCPU"
    make install
    echo "[vpx] Build complete"
else
    echo "[vpx] Already built, skipping"
fi

echo ""

# =============================================================================
# Step 4.5: Build SVT-AV1 (encoder only, static) — CMake
# =============================================================================

echo "=== Building SVT-AV1 (encoder) ==="
cd "$SCRATCH_DIR/SVT-AV1-v${SVT_AV1_VERSION}"

if [ ! -f "$DEPS_DIR/lib/libSvtAv1Enc.a" ]; then
    rm -rf buildmac
    cmake -S . -B buildmac \
        -DCMAKE_INSTALL_PREFIX="$DEPS_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_APPS=OFF \
        -DBUILD_DEC=OFF \
        -DBUILD_ENC=ON \
        -DBUILD_TESTING=OFF \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_OSX_SYSROOT="$SDK_PATH"
    cmake --build buildmac -j"$NCPU" --target install
    echo "[svt-av1] Build complete"
else
    echo "[svt-av1] Already built, skipping"
fi

echo ""

# =============================================================================
# Step 5: Build FFmpeg
# =============================================================================

echo "=== Building FFmpeg ==="
cd "$SCRATCH_DIR/ffmpeg-${FFMPEG_VERSION}"

if [ ! -f "$INSTALL_DIR/lib/libavformat.a" ]; then
    make clean 2>/dev/null || true

    # Set pkg-config to find our deps
    export PKG_CONFIG_PATH="$DEPS_DIR/lib/pkgconfig"

    # Use 'xcrun -sdk macosx clang' as CC so both the target and host compiler
    # tests find system headers via the macOS SDK. Also set --host-cc for safety.
    ./configure \
        --prefix="$INSTALL_DIR" \
        --arch=arm64 \
        --target-os=darwin \
        --cc="xcrun -sdk macosx clang" \
        --host-cc="xcrun -sdk macosx clang" \
        --enable-static \
        --disable-shared \
        --enable-pic \
        --enable-version3 \
        --enable-videotoolbox \
        --enable-audiotoolbox \
        --enable-libdav1d \
        --enable-libvpx \
        --enable-libopus \
        --enable-libsvtav1 \
        --disable-gpl \
        --disable-nonfree \
        --disable-encoders \
        --enable-encoder=libvpx_vp9 \
        --enable-encoder=libsvtav1 \
        --disable-muxers \
        --enable-muxer=webm \
        --enable-muxer=matroska \
        --enable-muxer=mp4 \
        --enable-muxer=ivf \
        --enable-bsf=av1_metadata \
        --disable-programs \
        --disable-doc \
        --disable-network \
        --disable-devices \
        --disable-filters \
        --enable-filter=scale \
        --enable-filter=aresample \
        --enable-filter=aformat \
        --extra-cflags="-mmacosx-version-min=$DEPLOYMENT_TARGET -I$DEPS_DIR/include" \
        --extra-ldflags="-mmacosx-version-min=$DEPLOYMENT_TARGET -L$DEPS_DIR/lib" \
        --pkg-config-flags="--static"

    make -j"$NCPU"
    make install
    echo "[ffmpeg] Build complete"
else
    echo "[ffmpeg] Already built, skipping"
fi

echo ""

# =============================================================================
# Step 6: Copy artifacts to SPM package
# =============================================================================

echo "=== Packaging for SPM ==="

# Clean output dirs
rm -rf "$OUTPUT_INCLUDE" "$OUTPUT_LIB"
mkdir -p "$OUTPUT_INCLUDE" "$OUTPUT_LIB"

# Copy FFmpeg headers
for lib in libavformat libavcodec libavutil libswscale libswresample; do
    cp -R "$INSTALL_DIR/include/$lib" "$OUTPUT_INCLUDE/"
done

# Copy FFmpeg static libs
for lib in libavformat libavcodec libavutil libswscale libswresample; do
    cp "$INSTALL_DIR/lib/${lib}.a" "$OUTPUT_LIB/"
done

# Copy third-party static libs
cp "$DEPS_DIR/lib/libdav1d.a" "$OUTPUT_LIB/"
cp "$DEPS_DIR/lib/libvpx.a" "$OUTPUT_LIB/"
cp "$DEPS_DIR/lib/libopus.a" "$OUTPUT_LIB/"
cp "$DEPS_DIR/lib/libSvtAv1Enc.a" "$OUTPUT_LIB/"   # SVT-AV1 encoder (BSD), #58

# Strip platform-foreign hwaccel headers. FFmpeg's `make install` ships
# every hwaccel header regardless of whether the underlying library was
# compiled in (which it isn't — this is the LGPL-safe macOS arm64 build).
# Leaving them in trips Swift's module-import on the transitive #include
# of d3d11.h / cuda.h / vulkan.h etc. — none of which exist on macOS.
# Keep hwcontext_videotoolbox.h; that's the legitimate macOS hwaccel.
for h in d3d11va.h dxva2.h jni.h mediacodec.h qsv.h vdpau.h; do
    rm -f "$OUTPUT_INCLUDE/libavcodec/$h"
done
for h in hwcontext_cuda.h hwcontext_d3d11va.h hwcontext_d3d12va.h \
         hwcontext_drm.h hwcontext_dxva2.h hwcontext_mediacodec.h \
         hwcontext_opencl.h hwcontext_qsv.h hwcontext_vaapi.h \
         hwcontext_vdpau.h hwcontext_vulkan.h; do
    rm -f "$OUTPUT_INCLUDE/libavutil/$h"
done
echo "[strip] Removed 17 platform-foreign headers (D3D/DXVA/QSV/CUDA/VAAPI/VDPAU/MediaCodec/OpenCL/Vulkan/DRM/JNI)"

echo ""

# =============================================================================
# Step 7: Verify
# =============================================================================

echo "=== Verification ==="

echo "Architecture check:"
for lib in "$OUTPUT_LIB"/*.a; do
    echo "  $(basename "$lib"): $(lipo -archs "$lib")"
done

echo ""
echo "GPL symbol check (should be empty):"
GPL_SYMBOLS=$(nm -g "$OUTPUT_LIB/libavcodec.a" 2>/dev/null | grep -i "x264\|x265\|fdk_aac" || true)
if [ -z "$GPL_SYMBOLS" ]; then
    echo "  PASS — No GPL symbols found"
else
    echo "  FAIL — GPL symbols detected:"
    echo "  $GPL_SYMBOLS"
    exit 1
fi

echo ""
echo "Library sizes:"
for lib in "$OUTPUT_LIB"/*.a; do
    SIZE=$(du -h "$lib" | cut -f1)
    echo "  $(basename "$lib"): $SIZE"
done

TOTAL_SIZE=$(du -ch "$OUTPUT_LIB"/*.a | tail -1 | cut -f1)
echo "  Total: $TOTAL_SIZE"

echo ""
echo "============================================"
echo "FFmpegXC build complete!"
echo "Headers: $OUTPUT_INCLUDE"
echo "Libs:    $OUTPUT_LIB"
echo "============================================"
