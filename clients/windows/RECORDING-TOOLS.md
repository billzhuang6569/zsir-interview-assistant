# Recording tools and corresponding source

This package contains separate ffmpeg.exe and ffprobe.exe programs, built by this project from unmodified source. No tools are downloaded when the user starts recording. The build disables network protocols and automatic external-library detection; the only enabled external codec library is x264.

- FFmpeg 9.0.2 source revision: https://github.com/FFmpeg/FFmpeg/commit/946fcce07b
- x264 source revision: https://github.com/mirror/x264/commit/c24e06c2e184345ceb33eb20a15d1024d9fd3497
- Complete corresponding source archives and exact build script: https://github.com/billzhuang6569/zsir-interview-assistant/releases/download/v0.3.0/recording-tools-source.tar.gz
- Build prerequisites on macOS: Homebrew mingw-w64 14.0.0_3 (GCC 16.2.0), nasm 3.02, pkgconf. Windows system DLLs are not bundled.

The combined FFmpeg/x264 executables are GPLv2-or-later. Their licenses accompany the binaries as FFmpeg-LICENSE.txt and x264-LICENSE.txt; upstream source archives contain their copyright notices. The application's MIT license does not replace these licenses. The application communicates with these separate executables through command-line arguments and pipes.

TOOLS-SHA256SUMS.txt records the exact shipped binaries. The Release's SHA256SUMS.txt covers the source bundle and installation archives. Extract the source bundle and run script/build-windows-tools.sh to rebuild; sources and checksums are included and no codec source modifications are required. Runtime support from GCC is covered by its Runtime Library Exception; compiler/toolchain components are not redistributed here.

Windows ARM64 uses its system's x64 emulation for these x64 tools. That does not constitute native ARM64 encoding or physical ARM64 acceptance.
