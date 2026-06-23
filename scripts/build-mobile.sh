#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/build-mobile.sh <target>

Targets:
  android-arm64
  android-armv7
  ios-device-arm64
  ios-sim-arm64

Builds pinned FFmpeg, x264, zimg, and the FFmpeg FFI wrapper for one mobile target.
Outputs are staged under BUILD_ROOT/<target>/package.
USAGE
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || { usage; exit 2; }
target="$1"
target_is_mobile "$target" || die "unknown mobile target: $target"

require_cmd git
require_cmd make
require_cmd patch
require_file "$(boundary_patch)"
ensure_common_dirs
"$REPO_ROOT/scripts/fetch-sources.sh"

target_root="$BUILD_ROOT/$target"
deps_root="$target_root/deps"
ffmpeg_build="$target_root/ffmpeg"
package_root="$target_root/package"
pkgconfig_dir="$target_root/pkgconfig"
reset_dir "$target_root"
mkdir -p "$deps_root" "$pkgconfig_dir" "$package_root"

prepare_ffmpeg_tree() {
  reset_dir "$ffmpeg_build"
  copy_clean_tree "$(ffmpeg_source_dir)" "$ffmpeg_build"
  (cd "$ffmpeg_build" && patch -p1 < "$(boundary_patch)")
}

compile_probe_wrapper() {
  local cc="$1"
  shift
  "$cc" \
    "$@" \
    -fPIC \
    -I"$ffmpeg_build" \
    -c "$REPO_ROOT/src/ffmpeg_ffi_probe.c" \
    -o "$target_root/ffmpeg_ffi_probe.o"
}

write_wrapper_objects() {
  find "$ffmpeg_build/fftools" -name '*.o' ! -name 'ffprobe.o' -print | sort \
    > "$target_root/fftools-objs.txt"
  printf '%s\n' "$target_root/ffmpeg_ffi_probe.o" >> "$target_root/fftools-objs.txt"
}

build_ios() {
  ios_target_vars "$target"
  require_cmd pkg-config

  local x264_src="$target_root/x264"
  local zimg_src="$target_root/zimg"
  local x264_prefix="$deps_root/x264"
  local zimg_prefix="$deps_root/zimg"
  local ffmpeg_prefix="$target_root/ffmpeg-install"

  copy_clean_tree "$(x264_source_dir)" "$x264_src"
  copy_clean_tree "$(zimg_source_dir)" "$zimg_src"

  log "build x264 for $target"
  (
    cd "$x264_src"
    if [ "$IOS_ARCH" = "arm64" ]; then
      sed -i.bak 's/-arch arm64//g' configure
      rm -f configure.bak
    fi
    CC="$IOS_CLANG -arch $IOS_ARCH -target $IOS_TARGET $IOS_MIN_FLAG -isysroot $IOS_SDK_PATH" \
    AR="$IOS_AR" \
    RANLIB="$IOS_RANLIB" \
    ./configure \
      --prefix="$x264_prefix" \
      --enable-pic \
      --enable-static \
      --disable-cli \
      --host=aarch64-apple-darwin \
      --sysroot="$IOS_SDK_PATH"
    make -j"$JOBS" install
  )

  log "build zimg for $target"
  (
    cd "$zimg_src"
    ./autogen.sh
    CC="$IOS_CLANG -arch $IOS_ARCH -target $IOS_TARGET $IOS_MIN_FLAG -isysroot $IOS_SDK_PATH" \
    CXX="$IOS_CLANGXX -arch $IOS_ARCH -target $IOS_TARGET $IOS_MIN_FLAG -isysroot $IOS_SDK_PATH" \
    AR="$IOS_AR" \
    RANLIB="$IOS_RANLIB" \
    STRIP="$IOS_STRIP" \
    CFLAGS="-fPIC" \
    CXXFLAGS="-fPIC" \
    LDFLAGS="-arch $IOS_ARCH -target $IOS_TARGET $IOS_MIN_FLAG -isysroot $IOS_SDK_PATH -lc++" \
    ./configure \
      --prefix="$zimg_prefix" \
      --host=aarch64-apple-darwin \
      --with-pic \
      --enable-static \
      --disable-shared \
      --disable-fast-install \
      --disable-dependency-tracking
    make -j"$JOBS" install
  )

  cp "$x264_prefix/lib/pkgconfig/x264.pc" "$pkgconfig_dir/x264.pc"
  cp "$zimg_prefix/lib/pkgconfig/zimg.pc" "$pkgconfig_dir/zimg.pc"
  normalize_zimg_pkg_config "$pkgconfig_dir/zimg.pc" "-lc++ -lm"
  prepare_ffmpeg_tree

  log "configure FFmpeg for $target"
  (
    cd "$ffmpeg_build"
    PKG_CONFIG_LIBDIR="$pkgconfig_dir" \
    PKG_CONFIG_PATH="$pkgconfig_dir" \
    ./configure \
      --prefix="$ffmpeg_prefix" \
      --target-os=darwin \
      --arch="$IOS_ARCH" \
      --enable-cross-compile \
      --cc="$IOS_CLANG" \
      --ar="$IOS_AR" \
      --ranlib="$IOS_RANLIB" \
      --strip="$IOS_STRIP" \
      --sysroot="$IOS_SDK_PATH" \
      --pkg-config="$(command -v pkg-config)" \
      --pkg-config-flags=--static \
      --enable-gpl \
      --enable-libx264 \
      --enable-libzimg \
      --enable-zlib \
      --enable-static \
      --disable-shared \
      --enable-pic \
      --disable-doc \
      --disable-ffplay \
      --disable-audiotoolbox \
      --disable-videotoolbox \
      --disable-debug \
      --extra-cflags="-arch $IOS_ARCH -target $IOS_TARGET $IOS_MIN_FLAG -isysroot $IOS_SDK_PATH" \
      --extra-ldflags="-arch $IOS_ARCH -target $IOS_TARGET $IOS_MIN_FLAG -isysroot $IOS_SDK_PATH -lc++"
    make -j"$JOBS"
  )

  compile_probe_wrapper \
    "$IOS_CLANG" \
    -arch "$IOS_ARCH" \
    -target "$IOS_TARGET" \
    "$IOS_MIN_FLAG" \
    -isysroot "$IOS_SDK_PATH"
  write_wrapper_objects
  cat > "$target_root/exported-symbols.txt" <<'EOF'
_ffmpeg_session_new
_ffmpeg_session_free
_ffmpeg_execute
_ffmpeg_cancel
_ffmpeg_probe_media_json
_ffmpeg_free_string
EOF

  log "link ffmpeg_ffi.dylib for $target"
  "$IOS_CLANG" \
    -dynamiclib \
    -arch "$IOS_ARCH" \
    -target "$IOS_TARGET" \
    "$IOS_MIN_FLAG" \
    -isysroot "$IOS_SDK_PATH" \
    -install_name @rpath/ffmpeg_ffi.dylib \
    -Wl,-exported_symbols_list,"$target_root/exported-symbols.txt" \
    @"$target_root/fftools-objs.txt" \
    -Wl,-force_load,"$ffmpeg_build/libavdevice/libavdevice.a" \
    -Wl,-force_load,"$ffmpeg_build/libavfilter/libavfilter.a" \
    -Wl,-force_load,"$ffmpeg_build/libavformat/libavformat.a" \
    -Wl,-force_load,"$ffmpeg_build/libavcodec/libavcodec.a" \
    -Wl,-force_load,"$ffmpeg_build/libswresample/libswresample.a" \
    -Wl,-force_load,"$ffmpeg_build/libswscale/libswscale.a" \
    -Wl,-force_load,"$ffmpeg_build/libavutil/libavutil.a" \
    -L"$x264_prefix/lib" \
    -L"$zimg_prefix/lib" \
    -lx264 -lzimg -lc++ -lz -lbz2 -liconv -lm \
    -framework Foundation \
    -framework AVFoundation \
    -framework CoreVideo \
    -framework CoreMedia \
    -framework CoreFoundation \
    -framework Security \
    -framework CoreImage \
    -o "$package_root/ffmpeg_ffi.dylib"

  cp "$REPO_ROOT/include/ffmpeg_ffi.h" "$package_root/ffmpeg_ffi.h"
  nm -gU "$package_root/ffmpeg_ffi.dylib" > "$package_root/exported-symbols.txt"
  otool -L "$package_root/ffmpeg_ffi.dylib" > "$package_root/otool-L.txt"
  file "$package_root/ffmpeg_ffi.dylib" > "$package_root/file.txt"
}

build_android() {
  android_target_vars "$target"
  require_cmd pkg-config

  local ndk_root
  ndk_root="$(android_ndk_root)"
  [ -d "$ndk_root" ] || die "set ANDROID_NDK_ROOT or install NDK $ANDROID_NDK_VERSION under ANDROID_HOME"
  local host_tag
  case "$(uname -s)" in
    Darwin) host_tag=darwin-x86_64 ;;
    Linux) host_tag=linux-x86_64 ;;
    *) die "unsupported Android build host: $(uname -s)" ;;
  esac
  local toolchain="$ndk_root/toolchains/llvm/prebuilt/$host_tag"
  local clang="$toolchain/bin/$ANDROID_TRIPLE$ANDROID_API-clang"
  local clangxx="$toolchain/bin/$ANDROID_TRIPLE$ANDROID_API-clang++"
  local ar="$toolchain/bin/llvm-ar"
  local ranlib="$toolchain/bin/llvm-ranlib"
  local strip="$toolchain/bin/llvm-strip"
  require_executable "$clang"
  require_executable "$clangxx"

  local x264_src="$target_root/x264"
  local zimg_src="$target_root/zimg"
  local x264_prefix="$deps_root/x264"
  local zimg_prefix="$deps_root/zimg"
  local ffmpeg_prefix="$target_root/ffmpeg-install"

  copy_clean_tree "$(x264_source_dir)" "$x264_src"
  copy_clean_tree "$(zimg_source_dir)" "$zimg_src"

  log "build x264 for $target"
  (
    cd "$x264_src"
    CC="$clang" AR="$ar" RANLIB="$ranlib" STRIP="$strip" \
    ./configure \
      --prefix="$x264_prefix" \
      --host="$ANDROID_TRIPLE" \
      --cross-prefix="$toolchain/bin/llvm-" \
      --sysroot="$toolchain/sysroot" \
      --enable-pic \
      --enable-static \
      --disable-cli
    make -j"$JOBS" install
  )

  log "build zimg for $target"
  (
    cd "$zimg_src"
    ./autogen.sh
    CC="$clang" CXX="$clangxx" AR="$ar" RANLIB="$ranlib" STRIP="$strip" \
    CFLAGS="-fPIC" CXXFLAGS="-fPIC" \
    ./configure \
      --prefix="$zimg_prefix" \
      --host="$ANDROID_TRIPLE" \
      --with-pic \
      --enable-static \
      --disable-shared \
      --disable-fast-install \
      --disable-dependency-tracking
    make -j"$JOBS" install
  )

  cp "$x264_prefix/lib/pkgconfig/x264.pc" "$pkgconfig_dir/x264.pc"
  cp "$zimg_prefix/lib/pkgconfig/zimg.pc" "$pkgconfig_dir/zimg.pc"
  normalize_zimg_pkg_config "$pkgconfig_dir/zimg.pc" "-lm"
  prepare_ffmpeg_tree

  log "configure FFmpeg for $target"
  (
    cd "$ffmpeg_build"
    PKG_CONFIG_LIBDIR="$pkgconfig_dir" \
    PKG_CONFIG_PATH="$pkgconfig_dir" \
    ./configure \
      --prefix="$ffmpeg_prefix" \
      --target-os=android \
      --arch="$FFMPEG_ARCH" \
      --cpu="$ANDROID_CPU" \
      --enable-cross-compile \
      --cc="$clang" \
      --cxx="$clangxx" \
      --ld="$clangxx" \
      --ar="$ar" \
      --ranlib="$ranlib" \
      --strip="$strip" \
      --pkg-config="$(command -v pkg-config)" \
      --pkg-config-flags=--static \
      --enable-gpl \
      --enable-libx264 \
      --enable-libzimg \
      --enable-zlib \
      --enable-shared \
      --disable-static \
      --disable-doc \
      --disable-ffplay \
      --disable-v4l2-m2m \
      --disable-debug \
      --extra-ldflags="-static-libstdc++ -Wl,-z,max-page-size=16384"
    make -j"$JOBS"
    make install
  )

  compile_probe_wrapper "$clang"
  mkdir -p "$package_root/jni/$ABI"
  cp "$ffmpeg_prefix/lib"/libav*.so "$package_root/jni/$ABI/"
  cp "$ffmpeg_prefix/lib"/libsw*.so "$package_root/jni/$ABI/"
  write_wrapper_objects
  cat > "$target_root/exports.map" <<'EOF'
{
  global:
    ffmpeg_session_new;
    ffmpeg_session_free;
    ffmpeg_execute;
    ffmpeg_cancel;
    ffmpeg_probe_media_json;
    ffmpeg_free_string;
  local:
    *;
};
EOF
  "$clangxx" \
    -shared \
    -static-libstdc++ \
    -Wl,-z,max-page-size=16384 \
    -Wl,--version-script="$target_root/exports.map" \
    @"$target_root/fftools-objs.txt" \
    -L"$package_root/jni/$ABI" \
    -lavdevice -lavfilter -lavformat -lavcodec -lswresample -lswscale -lavutil \
    -L"$x264_prefix/lib" \
    -L"$zimg_prefix/lib" \
    -lx264 -lzimg -lz -lm \
    -o "$package_root/jni/$ABI/libffmpeg_ffi.so"
  cp "$REPO_ROOT/include/ffmpeg_ffi.h" "$package_root/ffmpeg_ffi.h"
}

case "$target" in
  ios-*) build_ios ;;
  android-*) build_android ;;
esac

write_manifest "$package_root/build-manifest.env" "TARGET=$target"
log "built mobile target $target under $package_root"
