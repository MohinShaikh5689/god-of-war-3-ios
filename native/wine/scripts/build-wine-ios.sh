#!/usr/bin/env bash
# Builds the iOS side of the Wine engine (Madeira: FEX + Wine + DXMT) as static libraries, on a macOS
# runner. The Windows side (the arm64ec-windows DLL farm, NLS files, prefix template) is tracked prebuilt
# in native/third_party/Madeira/app/Madeira and is not rebuilt here.
#
# Madeira's own scripts (build/*/build.sh) do the compiling. They were written for its developer's Mac
# and assume inputs a clean checkout does not have (docs/WINE_ENGINE.md, "Inputs Madeira does not
# record"); the stages below create those first:
#   - wine/build-macos: a configured Wine tree (config.h and the widl-generated headers);
#   - a base libwineserver.a: wineserver/build.sh only replaces members of an existing archive;
#   - LLVM 15 for iOS (airconv) and libdxmt_combined.a: dxmt-ios/build.sh only refreshes that archive.
#
# Usage: build-wine-ios.sh [stage...]   (default: every stage, in order)
# Stages: mingw freetype winehost gnutls ffmpeg fex ntdll win32u wineserver llvm dxmt collect
# Output: native/wine/out/lib/*.a (what the engine links), native/wine/out/logs/<stage>.log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
M="$ROOT/native/third_party/Madeira"
TC="$M/toolchains"
OUT="$ROOT/native/wine/out"
LOGS="$OUT/logs"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

MINGW=llvm-mingw-20260421-ucrt-macos-universal
MINGW_SHA256=bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7
FREETYPE_TAG=VER-2-13-3
LLVM_TAG=llvmorg-15.0.7

mkdir -p "$TC" "$LOGS" "$OUT/lib"
# llvm-objcopy (wineserver's symbol renames) and the mingw compilers (Wine's configure) come from
# llvm-mingw; bison 3 and flex from Homebrew (macOS ships bison 2.3).
export PATH="$TC/$MINGW/bin:$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"
# ccache in front of the scripts' `xcrun -sdk iphoneos clang` (shims/xcrun).
export PATH="$ROOT/native/wine/scripts/shims:$PATH"

stage_mingw() {
    [ -x "$TC/$MINGW/bin/llvm-objcopy" ] && return
    local tarball="$TC/$MINGW.tar.xz"
    curl -fL -o "$tarball" "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$MINGW.tar.xz"
    echo "$MINGW_SHA256  $tarball" | shasum -a 256 -c
    tar -xJf "$tarball" -C "$TC"
    rm "$tarball"
}

stage_freetype() {
    [ -f "$M/build/freetype-ios/build/libfreetype.a" ] && return
    [ -d "$M/research/freetype" ] ||
        git clone --depth 1 --branch "$FREETYPE_TAG" https://github.com/freetype/freetype.git "$M/research/freetype"
    bash "$M/build/freetype-ios/build.sh"
}

# The unix-side scripts include wine/build-macos/include/config.h and the headers widl generates from
# include/*.idl. Madeira's configure line is not recorded; this is the macOS host with aarch64 PE, which
# build/dxmt-ios/README.md says the tree was. ntdll's dwrite unixlib reads the same generated headers
# from build-arm64ec/include, which here points at this tree.
stage_winehost() {
    local w="$M/wine" b="$M/wine/build-macos"
    if [ ! -f "$b/config.status" ]; then
        mkdir -p "$b"
        (cd "$b" && ../configure --enable-archs=aarch64 --without-x --without-freetype --disable-tests)
    fi
    make -C "$b" -j"$JOBS" include/all
    mkdir -p "$w/build-arm64ec"
    [ -e "$w/build-arm64ec/include" ] || ln -s ../build-macos/include "$w/build-arm64ec/include"
}

# GnuTLS and FFmpeg come from pinned tarballs and are cached by the workflow; a restored build is kept.
stage_gnutls() {
    [ -f "$TC/gnutls-ios/include/gnutls/gnutls.h" ] && return
    bash "$M/build/gnutls-ios/build.sh"
}
stage_ffmpeg() {
    [ -f "$TC/ffmpeg-ios/include/libavcodec/avcodec.h" ] && [ -f "$M/app/Madeira/libavcodec.a" ] && return
    bash "$M/build/ffmpeg/build.sh"
}
# fex-ios/build.sh's configure (Madeira's options) stops on CMake 4 and Xcode 26: FEX needs the processor
# named for iOS and TUNE_CPU off, as native/scripts/build-ios.sh found for our own FEX. Configured here
# with those added; the script then only builds.
stage_fex() {
    local b="$M/FEX/build-ios"
    [ -f "$b/CMakeCache.txt" ] ||
        cmake -S "$M/FEX" -B "$b" -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 \
            -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
            -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF \
            -DBUILD_FEX_LINUX_TESTS=OFF -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF \
            -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON -DENABLE_LTO=OFF -DENABLE_ZYDIS=OFF \
            -DENABLE_GDB_SYMBOLS=OFF -DTUNE_CPU=none -DTUNE_ARCH=generic \
            -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON -DCMAKE_DISABLE_FIND_PACKAGE_unordered_dense=ON \
            -DCMAKE_DISABLE_FIND_PACKAGE_range-v3=ON
    bash "$M/build/fex-ios/build.sh"
}
stage_ntdll() { bash "$M/build/ntdll-unix/build.sh"; }
stage_win32u() { bash "$M/build/win32u-unix/build.sh"; }

# wineserver/build.sh compiles its patched files and swaps them into an existing libwineserver.a. The
# base is the rest of wine/server/*.c, built with the same flags; a file that does not compile for iOS
# is fine when the script replaces it (its list of patched objects), and an error otherwise.
stage_wineserver() {
    local s="$M/build/wineserver" obj="$M/build/wineserver/obj/base" w="$M/wine"
    local replaced=" main mach request unicode fd process window user mapping class region queue winstation
                     thread sock object async event semaphore handle inproc_sync "
    local flags=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
        -I"$w/include" -I"$w/include/wine" -I"$w/build-macos/include" -I"$s" -I"$w/server"
        -I"$M/build/ntdll-unix/shims" -I"$M/build/madsync" -DHAVE_LINUX_NTSYNC_H=1
        -include "$s/config_ios.h" -include stdarg.h -include "$s/unicode_fix.h"
        -include "$s/wineserver_ios_kill.h"
        -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\" -D__WINESRC__ -DWINE_IOS=1
        -Dmain=wineserver_main -Wno-implicit-function-declaration)
    rm -rf "$obj" && mkdir -p "$obj"
    local src name failed=""
    for src in "$w"/server/*.c; do
        name=$(basename "$src" .c)
        if ! xcrun -sdk iphoneos clang "${flags[@]}" -c "$src" -o "$obj/$name.o" 2>"$obj/$name.err"; then
            case "$replaced" in
                *" $name "*) echo "  base $name: does not compile for iOS, replaced by the patched file" ;;
                *) failed="$failed $name"; cat "$obj/$name.err" ;;
            esac
        fi
    done
    [ -z "$failed" ] || { echo "wineserver base: failed:$failed"; return 1; }
    rm -f "$M/app/Madeira/libwineserver.a" "$s/obj/libwineserver.a"
    xcrun -sdk iphoneos ar rcs "$M/app/Madeira/libwineserver.a" "$obj"/*.o
    bash "$s/build.sh" all
}

# LLVM 15.0.7 for iOS: llvm-tblgen for the macOS host first, then the libraries for iOS with no
# targets, as build/dxmt-ios/README.md describes, including its AddLLVM.cmake change (-dead_strip
# instead of --gc-sections, which Apple's linker rejects).
stage_llvm() {
    local src="$TC/llvm-project" host="$TC/llvm-host-build" ios="$TC/llvm-ios-build"
    [ -f "$ios/.done" ] && return
    if [ ! -d "$src/llvm" ]; then
        git clone --depth 1 --branch "$LLVM_TAG" --filter=blob:none --sparse \
            https://github.com/llvm/llvm-project.git "$src"
        git -C "$src" sparse-checkout set llvm cmake third-party
    fi
    sed -i '' 's/MATCHES "Darwin")/MATCHES "Darwin|iOS")/' "$src/llvm/cmake/modules/AddLLVM.cmake"
    local common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS=
        -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF
        -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF)
    cmake -S "$src/llvm" -B "$host" "${common[@]}"
    cmake --build "$host" --target llvm-tblgen
    cmake -S "$src/llvm" -B "$ios" "${common[@]}" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
        -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 \
        -DLLVM_TARGET_ARCH=host -DLLVM_TABLEGEN="$host/bin/llvm-tblgen" \
        -DLLVM_BUILD_TOOLS=OFF -DLLVM_BUILD_UTILS=OFF
    # Only the libraries: LLVM's tools (llvm-lib, the fuzzers) are still built with tools off, and
    # their link fails on iOS (ld: unknown options: -z). airconv needs none of them.
    local libs
    libs=$(ninja -C "$ios" -t targets all | sed -n 's#^\(lib/libLLVM[A-Za-z0-9]*\.a\):.*#\1#p')
    [ -n "$libs" ] || { echo "no libLLVM*.a targets in $ios"; return 1; }
    ninja -C "$ios" $libs
    touch "$ios/.done"
}

# dxmt-ios/build.sh builds libdxmt_unix.a; the app links it merged with LLVM's libraries.
stage_dxmt() {
    xcrun -sdk iphoneos metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain
    local d="$M/build/dxmt-ios"
    rm -f "$d/libdxmt_combined.a" "$d/libdxmt_unix.a" "$d"/obj/*.err
    # airconv_context.cpp links three AIR shaders embedded as C arrays; DXMT's meson makes them
    # (src/airconv/meson.build: metalir_generator, then hexdump_generator), Madeira's script does not.
    local h="$d/shader-headers" shader name
    mkdir -p "$h"
    for shader in "$M"/dxmt/src/airconv/shaders/air_{msad,samplepos,tessellation}.metal; do
        name=$(basename "$shader" .metal)
        (cd "$h" && xcrun -sdk macosx metal -std=metal3.1 --target=air64-apple-macos14.0 \
            -o "$name.air" -c "$shader" && xxd -n "$name" -i "$name.air" "$name.h")
    done
    if ! bash "$d/build.sh"; then
        local e
        for e in "$d"/obj/*.err; do [ -s "$e" ] && { echo "--- $(basename "$e")"; head -n 40 "$e"; }; done
        return 1
    fi
    libtool -static -o "$d/libdxmt_combined.a" "$d/libdxmt_unix.a" "$TC"/llvm-ios-build/lib/libLLVM*.a
}

# Everything the engine links, in one folder (names as Madeira's Xcode project links them).
stage_collect() {
    local a="$M/app/Madeira" f="$M/FEX/build-ios"
    cp "$a"/lib{ntdll_unix,win32u_unix,wineserver,gmp,nettle,hogweed,gnutls}.a "$OUT/lib/"
    cp "$a"/lib{avformat,avcodec,swresample,avutil}.a "$OUT/lib/"
    cp "$M/build/dxmt-ios/libdxmt_combined.a" "$OUT/lib/"
    cp "$f"/FEXCore/Source/lib{FEXCore,FEXCore_Base}.a "$OUT/lib/"
    find "$f" -name 'libJemallocLibs.a' -o -name 'libcephes_128bit.a' -o -name 'libfmt.a' \
        -o -name 'libsoftfloat_3e.a' -o -name 'libxxhash.a' | xargs -I{} cp {} "$OUT/lib/"
    ls -l "$OUT/lib"
}

STAGES=(mingw freetype winehost gnutls ffmpeg fex ntdll win32u wineserver llvm dxmt collect)
[ $# -gt 0 ] && STAGES=("$@")
failed=()
for s in "${STAGES[@]}"; do
    echo "::group::$s"
    # Shown live (a quiet step looks stuck for the hour LLVM takes) and kept per stage. Not run as an
    # `if` condition: bash ignores set -e inside one, so a failing command would not stop the stage.
    set +e
    ( set -euo pipefail; "stage_$s" ) 2>&1 | tee "$LOGS/$s.log"
    status=${PIPESTATUS[0]}
    set -e
    if [ "$status" -eq 0 ]; then
        echo "== $s: OK"
    else
        echo "== $s: FAILED (log: native/wine/out/logs/$s.log)"
        failed+=("$s")
    fi
    echo "::endgroup::"
done
[ ${#failed[@]} -eq 0 ] || { echo "Failed stages: ${failed[*]}"; exit 1; }
