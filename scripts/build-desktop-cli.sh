#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  scripts/build-desktop-cli.sh <target>

Targets:
  desktop-darwin-universal
  desktop-linux-x64
  desktop-linux-arm64
  desktop-windows-x64
  desktop-windows-arm64

Builds project-owned ffmpeg and ffprobe CLI artifacts. macOS universal is produced
from darwin arm64 and x64 slices.
USAGE
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || { usage; exit 2; }
target="$1"
target_is_desktop "$target" || die "unknown desktop target: $target"

require_cmd make
require_cmd pkg-config
ensure_common_dirs
"$REPO_ROOT/scripts/fetch-sources.sh"

desktop_host_arg() {
  case "$DESKTOP_OS:$DESKTOP_ARCH" in
    darwin:arm64) printf '%s\n' aarch64-apple-darwin ;;
    darwin:x86_64) printf '%s\n' x86_64-apple-darwin ;;
    mingw32:x86_64) printf '%s\n' x86_64-w64-mingw32 ;;
    mingw32:aarch64) printf '%s\n' aarch64-w64-mingw32 ;;
    *) printf '%s\n' "" ;;
  esac
}

build_one_desktop() {
  local one_target="$1"
  desktop_target_vars "$one_target"
  local target_root="$BUILD_ROOT/$one_target"
  local deps_root="$target_root/deps"
  local ffmpeg_build="$target_root/ffmpeg"
  local pkgconfig_dir="$target_root/pkgconfig"
  local prefix="$target_root/install"
  local x264_src="$target_root/x264"
  local zimg_src="$target_root/zimg"
  local x264_prefix="$deps_root/x264"
  local zimg_prefix="$deps_root/zimg"
  reset_dir "$target_root"
  mkdir -p "$deps_root" "$pkgconfig_dir"
  copy_clean_tree "$(x264_source_dir)" "$x264_src"
  copy_clean_tree "$(zimg_source_dir)" "$zimg_src"
  copy_clean_tree "$(ffmpeg_source_dir)" "$ffmpeg_build"

  local cc="${CC:-cc}"
  local cxx="${CXX:-c++}"
  local ar="${AR:-ar}"
  local ranlib="${RANLIB:-ranlib}"
  local strip="${STRIP:-strip}"
  local pkg_config="${PKG_CONFIG:-pkg-config}"
  local host
  local exe_suffix=""
  local extra_cflags=""
  local extra_ldflags=""
  local ffmpeg_cross_flags=()
  if [ "$DESKTOP_OS" = "darwin" ]; then
    extra_cflags="-arch $DESKTOP_ARCH"
    extra_ldflags="-arch $DESKTOP_ARCH"
    ffmpeg_cross_flags+=(--enable-cross-compile)
  fi
  if [ "$DESKTOP_OS" = "mingw32" ]; then
    local cross_prefix
    case "$DESKTOP_ARCH" in
      x86_64) cross_prefix=x86_64-w64-mingw32 ;;
      aarch64) cross_prefix=aarch64-w64-mingw32 ;;
      *) die "unsupported Windows desktop architecture: $DESKTOP_ARCH" ;;
    esac
    cc="${CC:-$cross_prefix-gcc}"
    cxx="${CXX:-$cross_prefix-g++}"
    ar="${AR:-$cross_prefix-ar}"
    ranlib="${RANLIB:-$cross_prefix-ranlib}"
    strip="${STRIP:-$cross_prefix-strip}"
    if command -v "$cross_prefix-pkg-config" >/dev/null 2>&1; then
      pkg_config="${PKG_CONFIG:-$cross_prefix-pkg-config}"
    fi
    require_cmd "$cc"
    require_cmd "$cxx"
    require_cmd "$ar"
    require_cmd "$ranlib"
    require_cmd "$strip"
    exe_suffix=".exe"
    extra_ldflags="-static -static-libgcc -static-libstdc++"
    ffmpeg_cross_flags+=(--enable-cross-compile --cross-prefix="$cross_prefix-")
  fi
  host="$(desktop_host_arg)"

  log "build desktop x264 for $one_target"
  (
    cd "$x264_src"
    args=(
      --prefix="$x264_prefix"
      --enable-pic
      --enable-static
      --disable-shared
      --disable-cli
    )
    if [ -n "$host" ]; then
      args+=(--host="$host")
    fi
    CC="$cc $extra_cflags" AR="$ar" RANLIB="$ranlib" STRIP="$strip" \
      ./configure "${args[@]}"
    make -j"$JOBS" install
  )

  log "build desktop zimg for $one_target"
  (
    cd "$zimg_src"
    ./autogen.sh
    args=(
      --prefix="$zimg_prefix"
      --with-pic
      --enable-static
      --disable-shared
      --disable-fast-install
      --disable-dependency-tracking
    )
    if [ -n "$host" ]; then
      args+=(--host="$host")
    fi
    CC="$cc" CXX="$cxx" AR="$ar" RANLIB="$ranlib" STRIP="$strip" \
    CFLAGS="$extra_cflags" CXXFLAGS="$extra_cflags" LDFLAGS="$extra_ldflags" \
      ./configure "${args[@]}"
    make -j"$JOBS" install
  )

  cp "$x264_prefix/lib/pkgconfig/x264.pc" "$pkgconfig_dir/x264.pc"
  cp "$zimg_prefix/lib/pkgconfig/zimg.pc" "$pkgconfig_dir/zimg.pc"
  case "$DESKTOP_OS" in
    darwin) normalize_zimg_pkg_config "$pkgconfig_dir/zimg.pc" "-lc++ -lm" ;;
    mingw32) normalize_zimg_pkg_config "$pkgconfig_dir/zimg.pc" "-lstdc++ -lm" ;;
    *) normalize_zimg_pkg_config "$pkgconfig_dir/zimg.pc" "-lstdc++ -lm" ;;
  esac

  log "configure desktop FFmpeg for $one_target"
  (
    cd "$ffmpeg_build"
    PKG_CONFIG_LIBDIR="$pkgconfig_dir" \
    PKG_CONFIG_PATH="$pkgconfig_dir" \
    ./configure \
      --prefix="$prefix" \
      --target-os="$DESKTOP_OS" \
      --arch="$FFMPEG_ARCH" \
      --cc="$cc" \
      --cxx="$cxx" \
      --ar="$ar" \
      --ranlib="$ranlib" \
      --strip="$strip" \
      --pkg-config="$(command -v "$pkg_config")" \
      --pkg-config-flags=--static \
      "${ffmpeg_cross_flags[@]}" \
      --enable-gpl \
      --enable-libx264 \
      --enable-libzimg \
      --enable-zlib \
      --enable-ffmpeg \
      --enable-ffprobe \
      --disable-ffplay \
      --disable-doc \
      --extra-cflags="$extra_cflags" \
      --extra-ldflags="$extra_ldflags"
    make -j"$JOBS"
    make install
  )
  mkdir -p "$target_root/bin"
  cp "$prefix/bin/ffmpeg$exe_suffix" "$target_root/bin/ffmpeg$exe_suffix"
  cp "$prefix/bin/ffprobe$exe_suffix" "$target_root/bin/ffprobe$exe_suffix"
  write_manifest "$target_root/bin/build-manifest.env" "TARGET=$one_target"
}

case "$target" in
  desktop-darwin-universal)
    require_cmd lipo
    build_one_desktop desktop-darwin-arm64
    build_one_desktop desktop-darwin-x64
    out="$DIST_ROOT/desktop/darwin-universal"
    reset_dir "$out"
    lipo -create \
      "$BUILD_ROOT/desktop-darwin-arm64/bin/ffmpeg" \
      "$BUILD_ROOT/desktop-darwin-x64/bin/ffmpeg" \
      -output "$out/ffmpeg"
    lipo -create \
      "$BUILD_ROOT/desktop-darwin-arm64/bin/ffprobe" \
      "$BUILD_ROOT/desktop-darwin-x64/bin/ffprobe" \
      -output "$out/ffprobe"
    chmod +x "$out/ffmpeg" "$out/ffprobe"
    ;;
  *)
    build_one_desktop "$target"
    desktop_target_vars "$target"
    out="$DIST_ROOT/desktop/${target#desktop-}"
    reset_dir "$out"
    cp "$BUILD_ROOT/$target/bin/"* "$out/"
    ;;
esac

case "$target" in
  desktop-windows-*)
    require_cmd zip
    archive="$out/ffmpeg.zip"
    rm -f "$archive"
    (cd "$out" && zip -Xqr "$archive" ffmpeg.exe ffprobe.exe)
    ;;
  *)
    archive="$out/ffmpeg.tar.gz"
    tar -C "$out" -czf "$archive" ffmpeg ffprobe
    ;;
esac
sha256_file "$archive" > "$archive.sha256"
write_manifest "$archive.manifest.env" "TARGET=$target" "ARTIFACT=$archive"
log "built desktop artifact $archive"
