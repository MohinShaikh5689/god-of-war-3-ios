// SPDX-License-Identifier: GPL-3.0-or-later
// Keyboard input for Windows games: a hardware keyboard through GCKeyboard, and the iOS keyboard as a
// text bridge (a three-finger tap on the game view shows and hides it). Both post Windows virtual keys
// with winios_post_key; Wine makes the scan codes and WM_CHAR from them. The maps are Madeira's
// (app/Madeira/HardwareInput.swift, HardwareKeyMap and PasteText.key(for:), at e3a88fd).
import GameController
import UIKit

enum Gow3WineKeys {
  /// Windows virtual-key code for a USB HID keyboard usage (GCKeyCode.rawValue), nil for a key Windows
  /// has no virtual key for.
  static func vk(forHIDUsage u: Int) -> Int32? {
    switch u {
    case 0x04...0x1D: return Int32(0x41 + (u - 0x04))   // a-z
    case 0x1E...0x26: return Int32(0x31 + (u - 0x1E))   // 1-9
    case 0x27: return 0x30                              // 0
    case 0x28: return 0x0D                              // Return
    case 0x29: return 0x1B                              // Escape
    case 0x2A: return 0x08                              // Backspace
    case 0x2B: return 0x09                              // Tab
    case 0x2C: return 0x20                              // Space
    case 0x2D: return 0xBD                              // -
    case 0x2E: return 0xBB                              // =
    case 0x2F: return 0xDB                              // [
    case 0x30: return 0xDD                              // ]
    case 0x31, 0x32: return 0xDC                        // backslash, ISO #
    case 0x33: return 0xBA                              // ;
    case 0x34: return 0xDE                              // '
    case 0x35: return 0xC0                              // `
    case 0x36: return 0xBC                              // ,
    case 0x37: return 0xBE                              // .
    case 0x38: return 0xBF                              // /
    case 0x39: return 0x14                              // Caps Lock
    case 0x3A...0x45: return Int32(0x70 + (u - 0x3A))   // F1-F12
    case 0x46: return 0x2C                              // Print Screen
    case 0x47: return 0x91                              // Scroll Lock
    case 0x48: return 0x13                              // Pause
    case 0x49: return 0x2D                              // Insert
    case 0x4A: return 0x24                              // Home
    case 0x4B: return 0x21                              // Page Up
    case 0x4C: return 0x2E                              // Delete
    case 0x4D: return 0x23                              // End
    case 0x4E: return 0x22                              // Page Down
    case 0x4F: return 0x27                              // Right
    case 0x50: return 0x25                              // Left
    case 0x51: return 0x28                              // Down
    case 0x52: return 0x26                              // Up
    case 0x53: return 0x90                              // Num Lock
    case 0x54: return 0x6F                              // keypad /
    case 0x55: return 0x6A                              // keypad *
    case 0x56: return 0x6D                              // keypad -
    case 0x57: return 0x6B                              // keypad +
    case 0x58: return 0x0D                              // keypad Enter
    case 0x59...0x61: return Int32(0x61 + (u - 0x59))   // keypad 1-9
    case 0x62: return 0x60                              // keypad 0
    case 0x63: return 0x6E                              // keypad .
    case 0x64: return 0xE2                              // ISO < >
    case 0x65: return 0x5D                              // Menu
    case 0x68...0x73: return Int32(0x7C + (u - 0x68))   // F13-F24
    case 0xE0: return 0xA2                              // left Control
    case 0xE1: return 0xA0                              // left Shift
    case 0xE2: return 0xA4                              // left Alt (Option)
    case 0xE3: return 0x5B                              // left Windows (Command)
    case 0xE4: return 0xA3                              // right Control
    case 0xE5: return 0xA1                              // right Shift
    case 0xE6: return 0xA5                              // right Alt
    case 0xE7: return 0x5C                              // right Windows
    default: return nil
    }
  }

  /// The US-layout key and whether it needs Shift, for a character the iOS keyboard typed.
  static func key(for ch: Character) -> (Int32, Bool)? {
    guard let a = ch.asciiValue else { return nil }
    switch a {
    case 10, 13: return (0x0D, false)
    case 9: return (0x09, false)
    case 32: return (0x20, false)
    case 65...90: return (Int32(a), true)
    case 97...122: return (Int32(a - 32), false)
    case 48...57: return (Int32(a), false)
    default: break
    }
    let keys: [Int32] = [0xBD, 0xBB, 0xDB, 0xDD, 0xDC, 0xBA, 0xDE, 0xBC, 0xBE, 0xBF, 0xC0]
    if let i = Array("-=[]\\;',./`").firstIndex(of: ch) { return (keys[i], false) }
    if let i = Array("_+{}|:\"<>?~").firstIndex(of: ch) { return (keys[i], true) }
    if let i = Array(")!@#$%^&*(").firstIndex(of: ch) { return (Int32(0x30 + i), true) }
    return nil
  }
}

/// A hardware keyboard's keys, raw (one callback per physical press or release, modifiers as keys, no
/// repeat), while `active`. Everything still held is released when it stops being active or disconnects.
final class Gow3WineHardwareKeyboard {
  private let post: (Int32, Bool) -> Void
  private var held = Set<Int32>()
  private var observers: [NSObjectProtocol] = []
  var active = false {
    didSet { if !active { releaseAll() } }
  }
  static var connected: Bool { GCKeyboard.coalesced?.keyboardInput != nil }

  init(post: @escaping (Int32, Bool) -> Void) {
    self.post = post
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] n in
      self?.attach(n.object as? GCKeyboard)
    })
    observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
      self?.releaseAll()
    })
    attach(GCKeyboard.coalesced)
  }

  deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

  private func attach(_ keyboard: GCKeyboard?) {
    guard let keyboard, let input = keyboard.keyboardInput else { return }
    keyboard.handlerQueue = .main
    input.keyChangedHandler = { [weak self] _, _, code, pressed in self?.key(code.rawValue, pressed) }
  }

  private func key(_ usage: Int, _ pressed: Bool) {
    guard let vk = Gow3WineKeys.vk(forHIDUsage: usage) else { return }
    if pressed {
      // A key pressed while the game was not on screen stays away from it until released.
      guard active, held.insert(vk).inserted else { return }
      post(vk, true)
    } else if held.remove(vk) != nil {
      post(vk, false)
    }
  }

  func releaseAll() {
    for vk in held { post(vk, false) }
    held.removeAll()
  }
}

/// The iOS keyboard as the game's keyboard: an invisible text input that types each character as its
/// key (with Shift where the US layout needs it), plus a bar for the keys the iOS keyboard has none for.
final class Gow3WineTextInput: UIView, UIKeyInput {
  var post: ((Int32, Bool) -> Void)?

  override var canBecomeFirstResponder: Bool { true }
  var hasText: Bool { true }
  var keyboardType: UIKeyboardType { get { .asciiCapable } set {} }
  var autocorrectionType: UITextAutocorrectionType { get { .no } set {} }
  var autocapitalizationType: UITextAutocapitalizationType { get { .none } set {} }
  var spellCheckingType: UITextSpellCheckingType { get { .no } set {} }
  var smartQuotesType: UITextSmartQuotesType { get { .no } set {} }
  var smartDashesType: UITextSmartDashesType { get { .no } set {} }
  var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set {} }

  private lazy var bar = makeBar()
  override var inputAccessoryView: UIView? { bar }

  /// Key transitions still to post, one per `step`. A key's down and up must not reach Wine together:
  /// games that poll the keyboard once a frame (DirectInput's GetDeviceState; FromSoftware's) never see a
  /// key that was released before the next poll, so each key is held for a few frames, as a finger would.
  private var pending: [(vk: Int32, down: Bool)] = []
  private var timer: Timer?
  private static let step: TimeInterval = 0.05

  private func press(_ vk: Int32, shift: Bool = false) {
    if shift { pending.append((0x10, true)) }
    pending.append((vk, true))
    pending.append((vk, false))
    if shift { pending.append((0x10, false)) }
    guard timer == nil else { return }
    let timer = Timer(timeInterval: Self.step, repeats: true) { [weak self] timer in
      guard let self, !self.pending.isEmpty else {
        timer.invalidate()
        self?.timer = nil
        return
      }
      let next = self.pending.removeFirst()
      self.post?(next.vk, next.down)
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    timer.fire()
  }

  func insertText(_ text: String) {
    // A hardware keyboard's keys already reach the game raw; UIKit would type each one a second time.
    if Gow3WineHardwareKeyboard.connected { return }
    for ch in text {
      guard let (vk, shift) = Gow3WineKeys.key(for: ch) else { continue }
      press(vk, shift: shift)
    }
  }

  func deleteBackward() {
    if !Gow3WineHardwareKeyboard.connected { press(0x08) }
  }

  private func makeBar() -> UIView {
    let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 48))
    scroll.backgroundColor = .secondarySystemBackground
    let row = UIStackView()
    row.axis = .horizontal
    row.spacing = 6
    let keys: [(String, Int32)] = [("Esc", 0x1B), ("Tab", 0x09), ("Enter", 0x0D), ("⌫", 0x08),
                                   ("←", 0x25), ("↑", 0x26), ("↓", 0x28), ("→", 0x27), ("Done", 0)]
    for (title, vk) in keys {
      let button = UIButton(type: .system)
      button.configuration = .tinted()
      button.setTitle(title, for: .normal)
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
      button.addAction(UIAction { [weak self] _ in
        if vk == 0 { self?.resignFirstResponder() } else { self?.press(vk) }
      }, for: .touchUpInside)
      row.addArrangedSubview(button)
    }
    row.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
      row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
      row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
      row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
      row.heightAnchor.constraint(equalToConstant: 40),
    ])
    return scroll
  }
}
