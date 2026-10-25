// SPDX-License-Identifier: GPL-3.0-or-later
// The Windows engine (WineCore.framework: Madeira's FEX + Wine + DXMT, native/wine/include/winecore.h).
// The app embeds it but loads it only for a Windows session: one engine per launch, so GoW3's
// launches never run its constructors or reserve its address space (docs/WINE_ENGINE.md).
import GameController
import Metal
import QuartzCore
import UIKit

final class Gow3WineEngine {
  private typealias Start = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
                                            Int32, Int32, Int32) -> Int32
  private typealias State = @convention(c) () -> Int32
  private typealias Failure = @convention(c) () -> UnsafePointer<CChar>
  private typealias SetLayer = @convention(c) (UnsafeMutableRawPointer) -> Void
  private typealias ScreenSize = @convention(c) (UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Void
  private typealias Touch = @convention(c) (Int32, Int32) -> Void
  private typealias Gamepad = @convention(c) (Int32, UnsafeRawPointer?) -> Void

  private let startFn: Start
  private let stateFn: State
  private let failureFn: Failure
  private let setLayerFn: SetLayer
  private let screenSizeFn: ScreenSize
  let touchDown: (Int32, Int32) -> Void
  let touchMove: (Int32, Int32) -> Void
  let touchUp: (Int32, Int32) -> Void
  private let gamepadFn: Gamepad

  /// Documents/wine, Madeira's prefix: games are copied into its drive_c.
  static var prefix: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("wine")
  }
  static var driveC: URL { prefix.appendingPathComponent("drive_c") }
  static var logURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("madeira-log.txt")
  }
  static var frameworkPath: String? {
    Bundle.main.privateFrameworksPath.map { $0 + "/WineCore.framework/WineCore" }
  }
  /// The DLL farm and the rest of Madeira's bundle resources (native/wine/scripts/embed-wine.sh).
  static var resourcesPresent: Bool {
    FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/arm64ec-windows/ntdll.dll")
  }

  private static var loaded: Gow3WineEngine?
  /// The engine, once a Windows session loaded it in this launch (never loads it).
  static var current: Gow3WineEngine? { loaded }

  struct LoadError: Error, CustomStringConvertible { let description: String }

  /// dlopen with RTLD_GLOBAL: Wine and DXMT find some of the framework's own symbols by name through
  /// dlsym(RTLD_DEFAULT, ...) (DXMT's macdrv_functions, for one).
  static func load() throws -> Gow3WineEngine {
    if let loaded { return loaded }
    guard let path = frameworkPath, FileManager.default.fileExists(atPath: path) else {
      throw LoadError(description: "This build has no WineCore.framework.")
    }
    guard resourcesPresent else { throw LoadError(description: "This build has no Windows DLLs (arm64ec-windows).") }
    guard let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
      throw LoadError(description: "WineCore did not load: " + (dlerror().map { String(cString: $0) } ?? "unknown"))
    }
    func symbol<T>(_ name: String, type: T.Type) throws -> T {
      guard let address = dlsym(handle, name) else { throw LoadError(description: "WineCore has no \(name).") }
      return unsafeBitCast(address, to: T.self)
    }
    func touch(_ name: String) throws -> (Int32, Int32) -> Void {
      let fn = try symbol(name, type: Touch.self)
      return { fn($0, $1) }
    }
    let engine = Gow3WineEngine(
      startFn: try symbol("winecore_start", type: Start.self), stateFn: try symbol("winecore_state", type: State.self),
      failureFn: try symbol("winecore_failure", type: Failure.self),
      setLayerFn: try symbol("winecore_set_layer", type: SetLayer.self),
      screenSizeFn: try symbol("winecore_screen_size", type: ScreenSize.self),
      touchDown: try touch("winios_post_touch_down"), touchMove: try touch("winios_post_touch_move"),
      touchUp: try touch("winios_post_touch_up"), gamepadFn: try symbol("winios_gamepad_set_state", type: Gamepad.self))
    loaded = engine
    return engine
  }

  private init(startFn: @escaping Start, stateFn: @escaping State, failureFn: @escaping Failure, setLayerFn: @escaping SetLayer,
               screenSizeFn: @escaping ScreenSize, touchDown: @escaping (Int32, Int32) -> Void,
               touchMove: @escaping (Int32, Int32) -> Void, touchUp: @escaping (Int32, Int32) -> Void, gamepadFn: @escaping Gamepad) {
    self.startFn = startFn; self.stateFn = stateFn; self.failureFn = failureFn; self.setLayerFn = setLayerFn
    self.screenSizeFn = screenSizeFn; self.touchDown = touchDown; self.touchMove = touchMove; self.touchUp = touchUp
    self.gamepadFn = gamepadFn
  }

  /// winecore_start: 0, or -1 (already running, or JIT is off). Runs with the debugger attached:
  /// Madeira's JIT pool is prepared through it, then it is detached.
  func start(exe: String, args: String, screenWidth: Int32, screenHeight: Int32) -> Int32 {
    startFn(exe, args, nil, screenWidth, screenHeight, 0)
  }

  /// enum winecore_state: 0 idle, 1 starting, 2 running, 3 exited, -1 failed.
  var state: Int32 { stateFn() }
  var failure: String { String(cString: failureFn()) }

  func setLayer(_ layer: CAMetalLayer) { setLayerFn(Unmanaged.passUnretained(layer).toOpaque()) }

  var screenSize: (Int32, Int32) {
    var w: Int32 = 0, h: Int32 = 0
    screenSizeFn(&w, &h)
    return (w, h)
  }

  /// struct winios_gamepad (Winios/WiniosGamepad.h, 20 bytes), written field by field: XInput's buttons,
  /// triggers 0-255, sticks in the full signed range with +y up. The transport owns `packet`.
  func setGamepad(_ index: Int32, buttons: UInt16, leftTrigger: UInt8, rightTrigger: UInt8,
                  lx: Int16, ly: Int16, rx: Int16, ry: Int16) {
    var raw = [UInt8](repeating: 0, count: 20)
    raw.withUnsafeMutableBytes { p in
      p.storeBytes(of: buttons, toByteOffset: 4, as: UInt16.self)
      p.storeBytes(of: leftTrigger, toByteOffset: 6, as: UInt8.self)
      p.storeBytes(of: rightTrigger, toByteOffset: 7, as: UInt8.self)
      p.storeBytes(of: lx, toByteOffset: 8, as: Int16.self)
      p.storeBytes(of: ly, toByteOffset: 10, as: Int16.self)
      p.storeBytes(of: rx, toByteOffset: 12, as: Int16.self)
      p.storeBytes(of: ry, toByteOffset: 14, as: Int16.self)
      p.storeBytes(of: UInt8(1), toByteOffset: 16, as: UInt8.self)   // connected
    }
    raw.withUnsafeBytes { gamepadFn(index, $0.baseAddress) }
  }

  func disconnectGamepad(_ index: Int32) { gamepadFn(index, nil) }

  /// Programs under drive_c (up to four folders deep), as C:\ paths, for the test screen.
  static func programs() -> [String] {
    let root = driveC
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return [] }
    var found: [String] = []
    for case let url as URL in walker {
      if walker.level > 4 { walker.skipDescendants(); continue }
      let relative = url.path.dropFirst(root.path.count + 1)
      // The prefix's own Windows folders hold Wine's programs, not games.
      if walker.level == 1, ["windows", "users", "ProgramData", "Program Files", "Program Files (x86)"].contains(String(relative)) {
        walker.skipDescendants(); continue
      }
      if url.pathExtension.lowercased() == "exe" {
        found.append("C:\\" + relative.replacingOccurrences(of: "/", with: "\\"))
      }
    }
    return found.sorted()
  }
}

/// The Windows game's screen: DXMT presents into this view's CAMetalLayer, touches become the guest's
/// mouse (aspect-fit, as the picture), and controllers are XInput pads 0-3.
final class Gow3WineGameViewController: UIViewController {
  let metalView = Gow3MetalView()
  private var engine: Gow3WineEngine?
  private var link: CADisplayLink?

  override func loadView() {
    metalView.backgroundColor = .black
    metalView.isMultipleTouchEnabled = false
    let layer = metalView.metalLayer
    layer.device = MTLCreateSystemDefaultDevice()
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = true
    layer.contentsGravity = .resizeAspect
    view = metalView
  }

  func attach(_ engine: Gow3WineEngine) {
    self.engine = engine
    engine.setLayer(metalView.metalLayer)
    link = CADisplayLink(target: self, selector: #selector(pollControllers))
    link?.add(to: .main, forMode: .common)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    metalView.metalLayer.contentsScale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
  }

  // MARK: Touch: one finger is the mouse, its position in guest pixels.

  private func guestPoint(_ touch: UITouch) -> (Int32, Int32)? {
    guard let engine else { return nil }
    let (gw, gh) = engine.screenSize
    guard gw > 0, gh > 0 else { return nil }
    let b = view.bounds
    let scale = min(b.width / CGFloat(gw), b.height / CGFloat(gh))
    let ox = (b.width - CGFloat(gw) * scale) / 2, oy = (b.height - CGFloat(gh) * scale) / 2
    let p = touch.location(in: view)
    let x = min(max((p.x - ox) / scale, 0), CGFloat(gw - 1)), y = min(max((p.y - oy) / scale, 0), CGFloat(gh - 1))
    return (Int32(x), Int32(y))
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    if let t = touches.first, let p = guestPoint(t) { engine?.touchDown(p.0, p.1) }
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    if let t = touches.first, let p = guestPoint(t) { engine?.touchMove(p.0, p.1) }
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    if let t = touches.first, let p = guestPoint(t) { engine?.touchUp(p.0, p.1) }
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchesEnded(touches, with: event) }

  // MARK: Controllers, sampled every frame (Madeira's GamepadInput mapping).

  private var connected = Set<Int32>()

  @objc private func pollControllers() {
    guard let engine else { return }
    let pads = GCController.controllers().compactMap(\.extendedGamepad).prefix(4)
    var seen = Set<Int32>()
    for (i, pad) in pads.enumerated() {
      let index = Int32(i)
      seen.insert(index)
      let map: [(GCControllerButtonInput?, UInt16)] = [
        (pad.dpad.up, 0x0001), (pad.dpad.down, 0x0002), (pad.dpad.left, 0x0004), (pad.dpad.right, 0x0008),
        (pad.buttonMenu, 0x0010), (pad.buttonOptions, 0x0020),
        (pad.leftThumbstickButton, 0x0040), (pad.rightThumbstickButton, 0x0080),
        (pad.leftShoulder, 0x0100), (pad.rightShoulder, 0x0200), (pad.buttonHome, 0x0400),
        (pad.buttonA, 0x1000), (pad.buttonB, 0x2000), (pad.buttonX, 0x4000), (pad.buttonY, 0x8000),
      ]
      var buttons: UInt16 = 0
      for (button, mask) in map where button?.isPressed == true { buttons |= mask }
      func axis(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
      func trigger(_ v: Float) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }
      engine.setGamepad(index, buttons: buttons, leftTrigger: trigger(pad.leftTrigger.value),
                        rightTrigger: trigger(pad.rightTrigger.value),
                        lx: axis(pad.leftThumbstick.xAxis.value), ly: axis(pad.leftThumbstick.yAxis.value),
                        rx: axis(pad.rightThumbstick.xAxis.value), ry: axis(pad.rightThumbstick.yAxis.value))
    }
    for gone in connected.subtracting(seen) { engine.disconnectGamepad(gone) }
    connected = seen
  }

  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { true }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }

  /// Presents a new one fullscreen over the topmost view controller; nil when there is no key window.
  static func present(completion: @escaping (Gow3WineGameViewController?) -> Void) {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    guard var top = windows.first(where: \.isKeyWindow)?.rootViewController else {
      completion(nil)
      return
    }
    while let presented = top.presentedViewController { top = presented }
    let controller = Gow3WineGameViewController()
    controller.modalPresentationStyle = .fullScreen
    controller.modalPresentationCapturesStatusBarAppearance = true
    top.present(controller, animated: false) {
      controller.view.layoutIfNeeded()
      completion(controller)
    }
  }
}
