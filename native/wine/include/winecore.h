// C API of WineCore.framework: Madeira's engine (FEX as Wine's ARM64EC module, Wine, DXMT) for Windows
// games. The app loads the framework with dlopen only for a Windows session (one engine per launch,
// docs/WINE_ENGINE.md) and finds these functions with dlsym.
//
// Files: the prefix is Documents/wine (games are copied into Documents/wine/drive_c), switches come from
// Documents/madeira.cfg, and Wine, FEX and DXMT log to Documents/madeira-log.txt, all as in Madeira.
#ifndef WINECORE_H
#define WINECORE_H

#ifdef __cplusplus
extern "C" {
#endif

enum winecore_state {
    WINECORE_IDLE = 0,
    WINECORE_STARTING = 1,   // JIT pool, wineserver, then the Windows process
    WINECORE_RUNNING = 2,    // the Windows process is up
    WINECORE_EXITED = 3,     // it ended; winecore_exit_status says how
    WINECORE_FAILED = -1,    // it never started; winecore_failure says why
};

// Starts a session on its own thread and returns at once (0, or -1 when one is already running or JIT
// is off). exe is a Windows path or a program name (C:\Games\Sekiro\sekiro.exe); args may be empty;
// workdir is a Windows path, or NULL for the program's own folder. screen_w/h size the guest's virtual
// monitor; pool_mb is the JIT pool (0: Madeira's 896, or madeira.cfg's pool).
int winecore_start(const char *exe, const char *args, const char *workdir, int screen_w, int screen_h,
                   int pool_mb);
int winecore_state(void);
// Why the session failed, or "" (valid until the next start).
const char *winecore_failure(void);
// The NTSTATUS a crashed program ended with, 1 when it was one, 0 for a clean exit.
int winecore_exit_status(unsigned int *status);

// The CAMetalLayer DXMT presents into (a CAMetalLayer *, passed as void * for C). Once, before the
// game creates its swapchain; it stays registered for the session.
void winecore_set_layer(void *metal_layer);
// The guest's virtual monitor in guest pixels, for mapping touches to winios_post_touch_*.
void winecore_screen_size(int *w, int *h);

// Input goes straight to Madeira's iOS display driver (Winios/Winios.h, Winios/WiniosGamepad.h, both
// exported by the framework): winios_post_touch_down/move/up, winios_post_key, winios_pointer and
// winios_gamepad_set_state.

#ifdef __cplusplus
}
#endif

#endif
