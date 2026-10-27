#!/usr/bin/env bash
# The 32-bit Windows DLL farm (native/third_party/Madeira/app/Madeira/i386-windows) that 32-bit games
# need: Wine's WoW64 layer and FEX's WOW64 module are already in aarch64-windows, and Madeira's launcher
# (WineProcessBridge.m) turns WoW64 on for an i386 .exe once i386-windows/ntdll.dll exists in the bundle.
# Built with Madeira's own script (build/wine-i386/build.sh, written for macOS but run there only on
# WSL), on a macOS runner, from the pinned Wine and DXMT commits so the PE side matches our unix side.
#
# Usage: build-wine-i386.sh        (does nothing when the farm is already there, e.g. from the cache)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
M="$ROOT/native/third_party/Madeira"
DEST="$M/app/Madeira/i386-windows"
B="$M/wine/build-i386"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

if [ -f "$DEST/ntdll.dll" ] && [ -f "$DEST/d3d9.dll" ] && [ -f "$DEST/winemetal.dll" ]; then
    echo "i386 farm present ($(ls "$DEST" | wc -l | tr -d ' ') files)"
    exit 0
fi

# llvm-mingw (i686-w64-mingw32-*), as the 64-bit engine build fetches it.
bash "$ROOT/native/wine/scripts/build-wine-ios.sh" mingw
export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"
# DXMT embeds AIR shaders compiled with the Metal toolchain.
xcrun -sdk macosx metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain

show_errors() {
    echo "--- errors in $B/madeira-i386-build.log"
    grep -E 'error:|Error [0-9]|No rule to make' "$B/madeira-i386-build.log" 2>/dev/null | head -60 || true
}
trap show_errors ERR

# Wine's modules first. DXMT's meson then looks up three static libraries in this tree (winecrt0, ntdll's
# and dbghelp's import libraries); build them by name in case no module needed them, then run the script
# again: the modules are up to date and it goes on to DXMT's i386 DLLs.
SKIP_DXMT=1 bash "$M/build/wine-i386/build.sh"
libs=$(grep -oE '^(dlls|libs)/(winecrt0|ntdll|dbghelp)/i386-windows/lib(winecrt0|ntdll|dbghelp)\.a' "$B/Makefile" | sort -u || true)
[ -z "$libs" ] || make -C "$B" -j"$JOBS" $libs
bash "$M/build/wine-i386/build.sh"

for f in ntdll.dll kernel32.dll d3d9.dll d3d9-emulated.dll d3d11.dll dxgi.dll winemetal.dll; do
    [ -f "$DEST/$f" ] || { echo "i386 farm: $f missing"; exit 1; }
done
du -sh "$DEST"
