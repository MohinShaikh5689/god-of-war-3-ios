// A Windows game session, without Madeira's UI: the order of Madeira's runWineFullSequence
// (app/Madeira/ContentView.swift) for a game started directly (no desktop, no Steam Dock):
// the program and screen in the environment, DXMT's options, the JIT pool from the debugger, the
// debugger detached, wineserver, then the Windows process. The C API is native/wine/include/winecore.h.
import Foundation
import QuartzCore

private enum Session {
    static let lock = NSLock()
    nonisolated(unsafe) static var state: Int32 = 0   // enum winecore_state
    nonisolated(unsafe) static var failure = strdup("")!

    static func set(_ s: Int32, failure reason: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        state = s
        if let reason {
            free(failure); failure = strdup(reason)!
            LogStore.shared.log(reason, level: .error)
        }
    }

    static var prefix: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("wine").path
    }
}

@_cdecl("winecore_state")
public func winecore_state() -> Int32 {
    Session.lock.lock(); defer { Session.lock.unlock() }
    return Session.state
}

@_cdecl("winecore_failure")
public func winecore_failure() -> UnsafePointer<CChar> {
    Session.lock.lock(); defer { Session.lock.unlock() }
    return UnsafePointer(Session.failure)
}

@_cdecl("winecore_exit_status")
public func winecore_exit_status(_ status: UnsafeMutablePointer<UInt32>) -> Int32 {
    wine_crash_exit_status(status)
}

@_cdecl("winecore_set_layer")
public func winecore_set_layer(_ layer: UnsafeMutableRawPointer) {
    madeira_display_set_layer(Unmanaged<CAMetalLayer>.fromOpaque(layer).takeUnretainedValue())
}

@_cdecl("winecore_screen_size")
public func winecore_screen_size(_ w: UnsafeMutablePointer<Int32>, _ h: UnsafeMutablePointer<Int32>) {
    winios_screen_size(w, h)
}

@_cdecl("winecore_start")
public func winecore_start(_ exe: UnsafePointer<CChar>, _ args: UnsafePointer<CChar>?, _ workdir: UnsafePointer<CChar>?,
                           _ screenW: Int32, _ screenH: Int32, _ poolMB: Int32) -> Int32 {
    let current = winecore_state()
    guard current != 1, current != 2 else { return -1 }
    guard jit_check_debugged() else {
        Session.set(-1, failure: "JIT is not enabled.")
        return -1
    }
    Session.set(1)

    // A fresh Documents/madeira-log.txt per session (the last one kept as madeira-log-prev.txt), and
    // stderr into it now: the bridges redirect it only when wineserver starts, after the JIT pool, whose
    // lines would otherwise reach only the system log.
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let log = docs.appendingPathComponent("madeira-log.txt"), prev = docs.appendingPathComponent("madeira-log-prev.txt")
    try? FileManager.default.removeItem(at: prev)
    try? FileManager.default.moveItem(at: log, to: prev)
    let fd = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 { dup2(fd, STDERR_FILENO); close(fd) }
    let (sw, sh) = (screenW, screenH)
    LogStore.shared.log("WineCore session: \(String(cString: exe)) \(sw)x\(sh); early claim: window 0x\(String(madeira_early_window_base, radix: 16)) pool 0x\(String(madeira_early_pool_base, radix: 16)) \(madeira_early_pool_size >> 20) MB")

    // What the bridge starts (Library.swift configureLaunch): the program, its arguments, its folder
    // when it is not the program's own, and the virtual monitor (GuestDisplay's MADEIRA_SCREEN_W/H).
    setenv("MADEIRA_EXE", exe, 1)
    if let args { setenv("MADEIRA_ARGS", args, 1) } else { setenv("MADEIRA_ARGS", "", 1) }
    if let workdir, workdir.pointee != 0 { setenv("MADEIRA_WORKDIR", workdir, 1) } else { unsetenv("MADEIRA_WORKDIR") }
    unsetenv("MADEIRA_DESKTOP")
    setenv("MADEIRA_SCREEN_W", String(screenW), 1)
    setenv("MADEIRA_SCREEN_H", String(screenH), 1)
    wine_exit_status_reset()

    // The pool size: the caller's, else madeira.cfg's pool (256-1152), else Madeira's standard 896 MB.
    var configured = Int(poolMB)
    if configured == 0 {
        configured = 896
        if let txt = MadeiraConfig.get("pool"), let v = Int(txt), v >= 256, v <= 1152 { configured = v }
    }
    let mb = configured

    DispatchQueue.global(qos: .userInitiated).async {
        // DXMT's options: madeira.cfg's dxmt line, then the game's own (ContentView, before the pool).
        var dxmt: [String] = []
        for txt in [MadeiraConfig.get("dxmt"), MadeiraConfig.gameValue("dxmt")] {
            dxmt += (txt ?? "").split(whereSeparator: { $0 == ";" || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        if dxmt.isEmpty { unsetenv("DXMT_CONFIG") } else { setenv("DXMT_CONFIG", dxmt.joined(separator: ";"), 1) }
        if getenv("DXMT_CENSUS_THROTTLE") == nil { setenv("DXMT_CENSUS_THROTTLE", "1", 0) }

        LogStore.shared.log("Allocating \(mb)MB JIT pool (BRK will suspend process)...")
        guard let pool = StikJITHelper.allocatePool(poolSize: mb * 1024 * 1024) else {
            Session.set(-1, failure: "JIT pool allocation failed: " + (StikJITHelper.poolFailure ?? "no reason recorded"))
            return
        }
        setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
        setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
        setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
        if let hole = StikJITHelper.poolHole {
            setenv("WINE_IOS_JIT_HOLE", String(format: "%lx:%lx", hole.off, hole.end), 1)
        } else { unsetenv("WINE_IOS_JIT_HOLE") }
        if let hole2 = StikJITHelper.poolHole2 {
            setenv("WINE_IOS_JIT_HOLE2", String(format: "%lx:%lx", hole2.off, hole2.end), 1)
        } else { unsetenv("WINE_IOS_JIT_HOLE2") }
        if let low = StikJITHelper.poolLow {
            setenv("WINE_IOS_JIT_TAIL_REGION", String(format: "%lx:%lx", low.rx, low.size), 1)
        } else { unsetenv("WINE_IOS_JIT_TAIL_REGION") }

        // Madeira detaches right after the pool (ml524): later, the larger VM map makes the debugger's
        // exit stall the whole app for about a minute.
        StikJITHelper.detachDebugger()

        let prefix = Session.prefix
        guard wineserver_start(prefix) == 0 else {
            Session.set(-1, failure: "wineserver did not start.")
            return
        }
        let wait = CFAbsoluteTimeGetCurrent()
        while wineserver_is_ready() == 0, wineserver_is_running() != 0, CFAbsoluteTimeGetCurrent() - wait < 2.0 {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard wine_process_start(prefix) == 0 else {
            Session.set(-1, failure: "The Wine process did not start.")
            return
        }
        Session.set(2)
        LogStore.shared.log("Wine process started: \(String(cString: getenv("MADEIRA_EXE")))", level: .success)
        while wine_process_is_running() != 0 { Thread.sleep(forTimeInterval: 0.25) }
        Session.set(3)
        LogStore.shared.log("Wine process ended.")
    }
    return 0
}
