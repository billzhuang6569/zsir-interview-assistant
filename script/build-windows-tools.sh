#!/usr/bin/env bash
# Cross-build on macOS with Homebrew mingw-w64, nasm and pkg-config.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TOOLS_BUILD_DIR:-${TMPDIR:-/tmp}/zsir-windows-tools}"
mkdir -p "$WORK/sources" "$WORK/prefix" "$WORK/tools"
WORK="$(cd "$WORK" && pwd)"
fetch() {
  local file="$1" url="$2" hash="$3"
  if [[ ! -f "$WORK/sources/$file" ]]; then
    if [[ -f "$ROOT/sources/$file" ]]; then cp "$ROOT/sources/$file" "$WORK/sources/$file"
    else curl -fL --retry 2 --max-time 180 -o "$WORK/sources/$file" "$url"; fi
  fi
  echo "$hash  $WORK/sources/$file" | shasum -a 256 -c -
}
fetch ffmpeg.tar.gz https://github.com/FFmpeg/FFmpeg/archive/946fcce07b.tar.gz 0aa2b1de2a5698b20a23e93d539a9a8e82ca0117496c5bdf05d198805f42bb3b
fetch x264.tar.gz https://github.com/mirror/x264/archive/c24e06c2e184345ceb33eb20a15d1024d9fd3497.tar.gz 090d730e867fc63631782a1287974635d1237d0fa7c6fd1d09fd543620a56689
mkdir -p "$WORK/x264" "$WORK/ffmpeg"
[[ -f "$WORK/x264/configure" ]] || tar -xf "$WORK/sources/x264.tar.gz" -C "$WORK/x264" --strip-components=1
[[ -f "$WORK/ffmpeg/configure" ]] || tar -xf "$WORK/sources/ffmpeg.tar.gz" -C "$WORK/ffmpeg" --strip-components=1
cd "$WORK/x264"
./configure --host=x86_64-w64-mingw32 --cross-prefix=x86_64-w64-mingw32- --prefix="$WORK/prefix" --enable-static --disable-cli --disable-opencl
make -j8
make install
cd "$WORK/ffmpeg"
# Minimal preview gate: allow only constant select expressions through FFmpeg's
# existing stdin filter command protocol. No socket/control-library dependency.
# The modified source is included in the corresponding-source archive below.
python3 - <<'PATCH_PREVIEW'
from pathlib import Path
path = Path("libavfilter/f_select.c")
source = path.read_text()
if "zsir_preview_command" not in source:
    marker = "const FFFilter ff_vf_select = {"
    command = '''static int zsir_preview_command(AVFilterContext *ctx, const char *cmd,
                                const char *arg, char *res, int res_len, int flags)
{
    SelectContext *s = ctx->priv;
    AVExpr *next = NULL;
    int ret;
    if (strcmp(cmd, "expr") || (strcmp(arg, "0") && strcmp(arg, "1")))
        return AVERROR(ENOSYS);
    ret = av_expr_parse(&next, arg, var_names, NULL, NULL, NULL, NULL, 0, ctx);
    if (ret < 0) return ret;
    av_expr_free(s->expr);
    s->expr = next;
    s->do_scene_detect = 0;
    return 0;
}

'''
    assert source.count(marker) == 1
    source = source.replace(marker, command + marker)
    source = source.replace("Select video frames to pass in output.", "Select video frames to pass in output. ZSir preview gate v1.")
    source = source.replace(marker + "\n", marker + "\n    .process_command = zsir_preview_command,\n")
    path.write_text(source)
PATCH_PREVIEW
PKG_CONFIG_LIBDIR="$WORK/prefix/lib/pkgconfig" ./configure --target-os=mingw32 --arch=x86_64 --cross-prefix=x86_64-w64-mingw32- --enable-cross-compile --pkg-config=pkg-config --pkg-config-flags=--static --extra-cflags="-I$WORK/prefix/include" --extra-ldflags="-L$WORK/prefix/lib -static -static-libgcc" --disable-autodetect --disable-everything --disable-network --disable-doc --disable-debug --disable-ffplay --enable-gpl --enable-libx264 --enable-mediafoundation --enable-d3d11va --enable-static --disable-shared --enable-ffmpeg --enable-ffprobe --enable-avdevice --enable-avfilter --enable-swscale --enable-swresample --enable-protocol=file,pipe --enable-indev=gdigrab,lavfi --enable-demuxer=mov,wav,bmp_pipe --enable-muxer=mp4,mov,image2pipe,null,pcm_f32le --enable-encoder=h264_mf,libx264,aac,mjpeg,pcm_f32le,pcm_s16le,wrapped_avframe --enable-decoder=wrapped_avframe,h264,aac,pcm_f32le,pcm_s16le,pcm_s24le,pcm_s32le,pcm_u8,bmp,rawvideo --enable-parser=h264,aac --enable-filter=ddagrab,hwdownload,select,scale,fps,split,aresample,apad,atrim,asetpts,anull,aformat,format,color,anullsrc,signalstats,metadata,null,trim,setpts
make -j8
cp ffmpeg.exe ffprobe.exe "$WORK/tools/"
cp COPYING.GPLv2 "$WORK/tools/FFmpeg-LICENSE.txt"
cp "$WORK/x264/COPYING" "$WORK/tools/x264-LICENSE.txt"
cp "$(brew --prefix mingw-w64)/COPYING" "$WORK/tools/MinGW-w64-LICENSE.txt"
cp "$(brew --prefix mingw-w64)/AUTHORS" "$WORK/tools/MinGW-w64-AUTHORS.txt"
mkdir -p "$WORK/source-release/script" "$WORK/source-release/clients/windows" "$WORK/source-release/sources"
cp "$WORK/sources/ffmpeg.tar.gz" "$WORK/sources/x264.tar.gz" "$WORK/source-release/sources/"
cp "$ROOT/script/build-windows-tools.sh" "$WORK/source-release/script/"
mkdir -p "$WORK/source-release/patches"
cp "$WORK/ffmpeg/libavfilter/f_select.c" "$WORK/source-release/patches/f_select.c"
cp "$ROOT/clients/windows/RECORDING-TOOLS.md" "$WORK/source-release/clients/windows/"
cp "$ROOT/clients/windows/RECORDING-TOOLS.md" "$WORK/tools/SOURCE-NOTICE.md"
cd "$WORK"
zip -r -q recording-tools-win-x64.zip tools
# Complete corresponding FFmpeg and x264 sources plus exact build script.
tar -czf recording-tools-source.tar.gz -C source-release .
shasum -a 256 recording-tools-win-x64.zip recording-tools-source.tar.gz
