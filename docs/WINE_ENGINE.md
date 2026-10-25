# Wine engine: Windows games (Sekiro) next to GoW3

Goal: Olympus runs two engines, one per launch, under one console-style launcher:
- **GoW3 engine**: this repo's port (gow3 runtime, standalone FEXCore, shadPS4 video core, MoltenVK).
- **Wine engine**: [Madeira](https://github.com/willfaust/Madeira)'s stack (FEX as Wine's ARM64EC
  module, Wine 11.4, DXMT for D3D9/10/11 on Metal, madeira-d3d12). First target: **Sekiro: Shadows
  Die Twice** (64-bit, D3D11, so DXMT).

Branch: `wine-engine`. Madeira is the submodule `native/third_party/Madeira`, pinned to e3a88fd
(2026-10-23); its forks pin FEX f59cab9 (the same commit as our own FEX), Wine 9129e96
(`madeira-lgpl`) and DXMT 128b297 (`ios-port`).

## Decisions
- **Two frameworks, one shell**: `Gow3Core.framework` and `WineCore.framework`, each with its own FEX
  build (standalone vs ARM64EC), kept apart by the two-level namespace. Only one engine is started per
  launch: both install signal handlers, own a JIT pool and reserve address space. Switching engines
  means reopening the app.
- **Steam later**: the first phases run games from a folder the user copies in through the Files app,
  like the GoW3 dump; Sekiro is tested that way, from a game folder the user supplies. Valve's own
  Windows Steam client (Madeira Dock's approach: the real client inside Wine) is an optional later phase. Madeira's native Steam sign-in, library
  and Cloud code is not planned.
- **No Madeira UI**: only its engine core is taken (below). The launcher is ours, in React Native: a
  console-style home with one tile per game (GoW3, then each Windows game), shared JIT setup and
  settings, and per-engine settings behind each tile.
- **Documents layout**: `Documents/gow3/` (unchanged) and `Documents/windows/` (`prefix/` for the
  Wine prefix, `games/<name>/` for the copied games).

## What is taken from Madeira
| Part | Where in Madeira | Becomes |
|---|---|---|
| iOS-side libraries (FEXCore, ntdll/win32u unix, wineserver, DXMT + LLVM 15, FFmpeg, GnuTLS) | `build/*`, built by `native/wine/scripts/build-wine-ios.sh` | linked into `WineCore.framework` |
| Engine bridge: FEX init, wineserver/process start, display shim, JIT allocator, Winios (window/input), pad output | `app/Madeira/{FEXBridge,JITAllocator,IOSDisplayShim,WineServerBridge,WineProcessBridge,PadOutput}*`, `Winios/` | `WineCore.framework` with a small C API (`native/wine/include/winecore.h`) |
| Windows side: the arm64ec DLL farm (261 DLLs incl. `ntdll`, `xtajit64`, `winemetal`, `d3d11`, `dxgi`, `d3d12`), NLS files, prefix template, converter dylib | `app/Madeira/{arm64ec-windows,nls,prefix-template.tar.gz,d3d12}` (tracked prebuilt) | app bundle resources under `Wine/` |
| Later (phase 6, optional) | `madeira-dock` (Valve's Steam client inside Wine) | |
| Not taken | SwiftUI app, `SwiftSteam` (native sign-in/library), Cloud saves, Wine Mono, WoW64 (32-bit) | |

## Inputs Madeira does not record
Its `docs/BUILDING.md` marks most steps unverified from a clean checkout. Found while porting:
1. `wine/build-macos`, a configured Wine tree, is read by the ntdll, win32u and wineserver scripts;
   its configure line is not recorded. Ours: macOS host, `--enable-archs=aarch64 --without-x`, then
   `make include/all` for the widl headers. `build-arm64ec/include` (dwrite) points at it.
2. `wineserver/build.sh` swaps patched objects into an existing `libwineserver.a`; the base is the rest
   of `wine/server/*.c`, which we compile with the same flags.
3. `dxmt-ios/build.sh` only refreshes `libdxmt_combined.a` (DXMT + LLVM). We build LLVM 15.0.7 for iOS
   (its README's recipe; `BUILDING.md` names a different LLVM commit) and merge the archive ourselves.
4. `research/freetype` (FreeType 2.13.3) is cloned by hand before `freetype-ios/build.sh`.

## Phases
1. **iOS libraries on CI**: `.github/workflows/wine.yml` builds every library from a clean checkout
   (artifact `wine-ios-libs`, logs in `wine-ios-logs`). DONE (2026-10-25, d65fe17): all 12 stages pass;
   three runs, then 9 minutes with the caches (LLVM, the tarball dependencies, ccache). Beyond the four
   inputs above, the fixes were FEX's configure for iOS (`CMAKE_SYSTEM_PROCESSOR`, `TUNE_CPU=none`), only
   LLVM's libraries (its tools fail to link for iOS), and airconv's three embedded AIR shader headers.
2. **WineCore.framework**: Madeira's engine as one dynamic framework with the C API in
   `native/wine/include/winecore.h`. IN PROGRESS. Steps:
   - a. **Builds and links on CI** (`framework` stage, artifact `WineCore-framework`): Madeira's C and
     Objective-C engine sources and its `StikJITHelper.swift` (the JIT pool), all unchanged, plus
     `native/wine/src`: `MadeiraShims.swift` (the three app types the pool code uses: `LogStore`,
     `MadeiraConfig`, `SigningStatus`) and `WineSession.swift` (`winecore_start` in the order of Madeira's
     `runWineFullSequence`: environment, DXMT options, JIT pool, debugger detach, wineserver, process).
     Compiled `-O0` like Madeira's Debug configuration, the one it runs games with. DONE (2026-10-25,
     e4b9748, four CI rounds): the gaps were `isDebuggerAttached` (a free function the pool code also
     uses), FEX's `JemallocLibs` (the `FEXCore::Allocator` hooks Madeira's app links but its script does
     not build), and three globals both wineserver and ntdll define (`supported_machines_count`,
     `native_machine`, `server_start_time`), renamed with the `ws_` prefix Madeira's sweep uses.
   - b. **In the app**: the framework is embedded but loaded with `dlopen` only for a Windows session.
     Madeira reserves the low address space a JIT pool and fixed-base `.exe` images need in a constructor
     (`madeira_early_va_claim` in `JITAllocator.c`: 128 MB at 0x140000000 and up to 1 GB above it) before
     UIKit and Metal fragment it. So choosing a Windows game records the choice and relaunches; a
     constructor in the app makes the same reservation for that launch only, and hands it to the framework.
     Madeira's bundle resources (`arm64ec-windows/`, `aarch64-windows/`, `nls/`, `prefix-template.tar.gz`,
     `cacert.pem`, `d3d12/`) go to the app bundle's root, where its bridges look for them, by a step after
     `xcodebuild` like the JIT helper's. Files stay in Madeira's layout: `Documents/wine` (the prefix;
     games in `drive_c`), `Documents/madeira.cfg`, `Documents/madeira-log.txt`.
   - c. **Game view**: a view controller like GoW3's with a `CAMetalLayer` (`winecore_set_layer`), touch
     mapped to the guest monitor (`winios_post_touch_*`), controllers to `winios_gamepad_set_state`.
     Written for 0.2.0 (`app/modules/gow3-core/ios/Gow3WineEngine.swift`, the System tab's "Windows engine
     (test)" panel). The JIT flow is GoW3's (built-in helper or StikDebug, same `universal.js`: Madeira's
     pool uses the same `brk #0xf00d` requests); only the step run while the debugger is attached differs
     (`winecore_start` instead of `gow3_jit_setup`). Both ways of getting Madeira's early reservation are in
     0.2.0, so one build can try both: a plain start (the framework's own constructor claims when it is
     loaded, late), and "Prepare launch" (the panel writes `Documents/wine/.early-claim`; at the next launch
     `Gow3WineEarlyClaim.c`, a constructor in the app, makes the claim before main and the engine's
     `madeira_early_*` globals take it when the framework loads). `winecore_start` starts a fresh
     `madeira-log.txt` (the last kept as `madeira-log-prev.txt`) with stderr in it, so the pool's lines are there. GoW3's FEX (in the app) and WineCore's share a commit; the
     one header our patches change (`OpcodeDispatcher.h`) changes signatures, so dyld's weak-symbol
     coalescing cannot mix the two copies' inline code.
   - d. **Exit**: a D3D11 test program from `Madeira/tests/dxmt` draws on the iPhone.
3. **Gow3Core.framework**: the GoW3 engine moves from the static `libgow3core_all.a` into its own
   framework, so both engines and their FEX copies sit side by side; the Expo module loads the chosen one.
4. **Console launcher**: the RN home becomes multi-game (tiles, a Windows game import from Files, per-game
   settings: executable, arguments, frame cap, touch layout). GoW3 keeps everything it has now.
5. **Sekiro**: boot from the user's game folder, then memory (8 GB iPhone, with the GoW3 file-backed
   memory lessons) and performance.
6. **Steam client (optional)**: Valve's Windows Steam client in the prefix, from `madeira-dock`.

## Per-game notes (from Madeira's sources, 2026-10-25)
Madeira has built-in settings lists only for RDR2, GTA V Enhanced, Ghost of Tsushima, God of War and
Horizon Zero Dawn (`app/Madeira/GameRecommendations.swift`); every other game gets the "standard" list, which
only turns a diagnostic trace off. The per-launch settings its library applies are defaults our session
already gets: Fastsync (`WineProcessBridge.m` exports `MADEIRA_FASTSYNC=auto` itself), the 60 FPS present
lock (`g_madeira_vsync_mode = 1` in DXMT), AVX off, no NVIDIA identity.
- **Silksong** (Unity, 64-bit D3D11): no list needed. Madeira's code has run Hollow Knight (about 2.2 GB,
  `signal_arm64_ios.c`) and handles Unity's quirks itself (`UnityCrashHandler64.exe` is skipped,
  `process_ios.c`). Start the game's own `.exe`, not `UnityCrashHandler64.exe`.
- **Sekiro** (FromSoftware, 64-bit D3D11): no list either, but Madeira has run Dark Souls III and Dark
  Souls Remastered, the same engine family. Touch must not reach the game as a mouse while a controller is
  used (Dark Souls Remastered switches to keyboard-and-mouse prompts and then ignores the pad;
  `docs/CONTROLLERS.md`): the Windows view sends no touches while a controller is connected. Win32u's
  foreground fix (on by default) covers games that read input only when their window is in front.
  Later tuning in `Documents/madeira.cfg`: `env.MADEIRA_THREAD_QOS = GXWorker*=user-initiated;FD4JobWorker*=utility`
  (made for Dark Souls III's worker threads), and the memory switches of Madeira's example config
  (`docs/madeira.cfg.example`: `swap-mb` file-backed guest memory, `totalphys`, `vram-mb`, `pool`), all off
  or default without a `madeira.cfg`; set them from Sekiro's first logs, not before.

## Risks
- **Steam client**: a heavy Chromium-based program, another memory cost on 8 GB if phase 6 happens.
- **Memory**: a 64-bit D3D11 game through Wine and FEX on 8 GB; Madeira's "Memory+" entitlement
  (increased memory limit) is needed, which AltStore keeps.
- **Debug only**: Madeira notes that Release builds have crashed the guest; the engine framework may
  need `-O` settings from its Debug configuration.
- **Licensing**: Madeira is GPL-3.0-or-later with the Madeira Converter Exception (Metal Shader
  Converter); Wine and FFmpeg are LGPL; the combined app stays GPL-3.0 and must keep Madeira's notices
  (`LICENSES/`, `THIRD-PARTY-NOTICES.md`). The VC++ runtime DLLs are not shipped.
