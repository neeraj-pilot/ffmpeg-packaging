#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in emcc em++ emar emranlib emmake emconfigure make pkg-config meson ninja; do
  require_cmd "$tool"
done
[[ "$(emcc --version | head -n 1)" == *" $EMSCRIPTEN_VERSION "* ]] ||
  die "activate Emscripten $EMSCRIPTEN_VERSION before building"
ensure_common_dirs
"$REPO_ROOT/scripts/fetch-sources.sh"

target_root="$BUILD_ROOT/wasm"
prefix="$target_root/install"
reset_dir "$target_root"
mkdir -p "$prefix"
copy_clean_tree "$(x264_source_dir)" "$target_root/x264"
copy_clean_tree "$(zimg_source_dir)" "$target_root/zimg"
copy_clean_tree "$(ffmpeg_source_dir)" "$target_root/ffmpeg"

export CFLAGS="-O2 -pthread -msimd128"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="$CFLAGS"

log "build Wasm x264"
(
  cd "$target_root/x264"
  patch -p1 < "$REPO_ROOT/patches/x264/encoder-open-cleanup.patch"
  emconfigure ./configure --prefix="$prefix" --host=x86-gnu \
    --enable-static --disable-cli --disable-asm \
    --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS"
  emmake make -j"$JOBS" install-lib-static
)

log "build Wasm zimg"
(
  cd "$target_root/zimg"
  ./autogen.sh
  emconfigure ./configure --prefix="$prefix" --host=wasm32-unknown-emscripten \
    --enable-static --disable-shared --disable-simd --disable-dependency-tracking
  emmake make -j"$JOBS" install
)
normalize_zimg_pkg_config "$prefix/lib/pkgconfig/zimg.pc" "-lc++ -lm"

fetch_dav1d_source
dav1d_source="$SOURCES_ROOT/dav1d-$DAV1D_VERSION"
cat > "$target_root/emscripten.ini" <<'EOF'
[binaries]
c = 'emcc'
ar = 'emar'
strip = 'emstrip'
[host_machine]
system = 'emscripten'
cpu_family = 'wasm32'
cpu = 'wasm32'
endian = 'little'
EOF
log "build Wasm dav1d"
meson setup "$target_root/dav1d-build" "$dav1d_source" \
  --cross-file "$target_root/emscripten.ini" --prefix "$prefix" --libdir lib \
  --default-library static --buildtype release --wrap-mode nodownload \
  -Denable_asm=false -Denable_tools=false -Denable_tests=false -Denable_examples=false
meson compile -C "$target_root/dav1d-build" -j "$JOBS"
meson install -C "$target_root/dav1d-build"

log "build Wasm FFmpeg and ffprobe"
cd "$target_root/ffmpeg"
patch -p1 < "$(boundary_patch)"
patch -p1 < "$REPO_ROOT/patches/ffmpeg-${FFMPEG_VERSION%.*}/wasm.patch"
PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH="$prefix/lib/pkgconfig" \
./configure \
  --target-os=none --arch=wasm --enable-cross-compile \
  --cc=emcc --cxx=em++ --ar=emar --ranlib=emranlib --nm=emnm \
  --pkg-config=pkg-config --pkg-config-flags=--static \
  --disable-autodetect --disable-stripping --disable-doc --disable-debug \
  --disable-network --disable-ffplay --disable-devices --enable-pthreads \
  --enable-gpl --enable-libx264 --enable-libzimg --enable-libdav1d --enable-zlib \
  --disable-encoders --enable-encoder=libx264,aac,mjpeg,png,pcm_s16le,rawvideo,wrapped_avframe \
  --extra-cflags="$CFLAGS -sUSE_ZLIB" --extra-ldflags="$LDFLAGS -sUSE_ZLIB" --optflags=-O2

cat > wasm-objects.mk <<'MAKE'
wasm-objects: $(OBJS-ffmpeg) $(OBJS-ffprobe) $(FF_DEP_LIBS)
MAKE
emmake make -j"$JOBS" -f Makefile -f wasm-objects.mk wasm-objects

objects=()
while IFS= read -r object; do objects+=("$object"); done < <(find fftools -name '*.o' -type f | sort)
output="$DIST_ROOT/wasm"
reset_dir "$output"
# Keep noExitRuntime in the incoming API: it affects generated pool lifetime
# even though the wrapper does not pass an override.
em++ -O2 -pthread -msimd128 --no-entry "${objects[@]}" \
  -Wl,--start-group libavdevice/libavdevice.a libavfilter/libavfilter.a \
  libavformat/libavformat.a libavcodec/libavcodec.a libswresample/libswresample.a \
  libswscale/libswscale.a libavutil/libavutil.a \
  "$prefix/lib/libx264.a" "$prefix/lib/libzimg.a" "$prefix/lib/libdav1d.a" \
  -Wl,--end-group -sUSE_ZLIB \
  -sMODULARIZE -sEXPORT_NAME=createFFmpegCore \
  -sINCOMING_MODULE_JS_API=mainScriptUrlOrBlob,locateFile,print,printErr,noExitRuntime,postRun \
  -sENVIRONMENT=worker -sALLOW_MEMORY_GROWTH -sINITIAL_MEMORY=64MB \
  -sSTACK_SIZE=2MB -sPTHREAD_POOL_SIZE=16 -sPTHREAD_POOL_SIZE_STRICT=2 \
  -sEXPORTED_FUNCTIONS=_ffmpeg_wasm_main,_ffprobe_wasm_main,_ffmpeg_wasm_set_timeout,_malloc,_free \
  -sEXPORTED_RUNTIME_METHODS=FS,stringToUTF8,lengthBytesUTF8,setValue \
  -lworkerfs.js --js-library "$REPO_ROOT/src/wasm/library.js" --pre-js "$REPO_ROOT/src/wasm/bind.js" -o "$output/ffmpeg-core.js"
write_manifest "$output/manifest.env" "EMSCRIPTEN_VERSION=$EMSCRIPTEN_VERSION" \
  "EMSDK_REVISION=$EMSDK_REVISION" "DAV1D_VERSION=$DAV1D_VERSION" \
  "DAV1D_SHA256=$DAV1D_SHA256"
mkdir -p "$output/licenses"
cp "$(ffmpeg_source_dir)/COPYING.GPLv2" "$output/licenses/ffmpeg.txt"
cp "$(x264_source_dir)/COPYING" "$output/licenses/x264.txt"
cp "$(zimg_source_dir)/COPYING" "$output/licenses/zimg.txt"
cp "$dav1d_source/COPYING" "$output/licenses/dav1d.txt"
cp "$(em-config CACHE)/ports/zlib/zlib-1.3.2/LICENSE" "$output/licenses/zlib.txt"
cp "$(em-config EMSCRIPTEN_ROOT)/LICENSE" "$output/licenses/emscripten.txt"
archive="$DIST_ROOT/ffmpeg-wasm.tar.gz"
tar -C "$output" -czf "$archive" .
printf '%s  %s\n' "$(sha256_file "$archive")" "$(basename "$archive")" > "$archive.sha256"
log "Wasm core ready under $output"
