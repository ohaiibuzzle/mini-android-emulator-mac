import AppKit
import CShm

/// `--start <avd>` boots that device next to the Devices window; `--headless` without its window (for scrcpy and the like
/// over adb), and `--port <even port>` on that console port, adb on the next, instead of the lowest free pair.
let flag = { (name: String) in CommandLine.arguments.firstIndex(of: name).flatMap { CommandLine.arguments.dropFirst($0 + 1).first } }

/// Panel orientation in quarter turns counter-clockwise, as mini-display reports it with each frame.
enum Rotation: Int { case portrait, landscape, reversePortrait, reverseLandscape }

/// POSIX shared memory QEMU's mini-display writes RGBA frames into. Not a mapped file: that is written back to disk,
/// hundreds of MB/s at 60 frames a second.
final class FrameBuffer: @unchecked Sendable {
  let path: String
  let ptr: UnsafeMutableRawPointer
  let size: Int

  init(maxSide: Int, count: Int, name: String) throws {
    // Square bound so rotation never overflows. Whole pages per frame: macOS rounds shm up to a page, and mini-display
    // splits the rounded size, so an unrounded frame size would shift every frame after the first.
    let page = Int(getpagesize())
    size = (maxSide * maxSide * 4 + page - 1) / page * page * count
    path = name
    shm_unlink(path)  // a leftover from a crashed run would refuse ftruncate
    let fd = mini_shm_open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0, ftruncate(fd, off_t(size)) == 0,
      let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), p != MAP_FAILED
    else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    close(fd)
    ptr = p
  }

  /// Drops the name once the other side has mapped it; the memory lives on until both unmap.
  func unlinkName() { shm_unlink(path) }

  deinit { munmap(ptr, size); unlinkName() }

  // shortcut: QEMU may reuse a buffer while a slow reader still draws it, so frames can tear; add a handshake if visible.
  func image(width: Int, height: Int, offset: Int = 0) -> CGImage? {
    guard offset + width * height * 4 <= size,
      let provider = CGDataProvider(dataInfo: nil, data: ptr + offset, size: width * height * 4, releaseData: { _, _, _ in })
    else { return nil }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}

@MainActor
final class ScreenView: NSView {
  var deviceSize = CGSize(width: 1, height: 1)
  let name: String
  let guest: GuestSetup
  let inputs: AsyncStream<Data>.Continuation  // mini-display messages
  private var lastImage: CGImage?
  private var angle: Int32 = 0

  init(name: String, guest: GuestSetup, inputs: AsyncStream<Data>.Continuation) {
    self.name = name
    self.guest = guest
    self.inputs = inputs
    super.init(frame: .zero)
    wantsLayer = true
    layer?.contentsGravity = .resizeAspect  // letterbox, never stretch (zoom / full screen)
    layer?.backgroundColor = .black
    spinner.style = .spinning
    spinner.controlSize = .large
    spinner.appearance = NSAppearance(named: .darkAqua)  // visible on the black background
    spinner.translatesAutoresizingMaskIntoConstraints = false
    addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    spinner.startAnimation(nil)
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  /// Shown until the guest posts its first frame, and again while it shuts down.
  private let spinner = NSProgressIndicator()
  private var spinnerLabel: NSTextField?

  func showShuttingDown() {
    let label = NSTextField(labelWithString: "Android is shutting down…")
    label.textColor = .white
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor), label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
    ])
    spinnerLabel = label
    layer?.contents = nil
    spinner.isHidden = false
    spinner.startAnimation(nil)
  }

  /// Where the letterboxed frame sits inside the view.
  private var imageRect: CGRect {
    let s = min(bounds.width / deviceSize.width, bounds.height / deviceSize.height)
    let size = CGSize(width: deviceSize.width * s, height: deviceSize.height * s)
    return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
  }
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // a tap on an inactive window still taps

  private var rotation = Rotation.portrait

  func show(_ image: CGImage, rotation: Rotation) {
    guard spinnerLabel == nil else { return }  // shutting down
    self.rotation = rotation
    deviceSize = CGSize(width: image.width, height: image.height)
    if !spinner.isHidden {
      spinner.stopAnimation(nil)
      spinner.isHidden = true
    }
    if let window, window.contentAspectRatio != deviceSize {
      window.contentAspectRatio = deviceSize
      // Rotation: keep the long side, shrink to fit the screen, stay centred where we were.
      let old = window.frame
      let visible = window.screen?.visibleFrame ?? old
      let chrome = old.height - window.contentLayoutRect.height
      let long = max(window.contentLayoutRect.width, window.contentLayoutRect.height)
      let scale = min(
        long / max(deviceSize.width, deviceSize.height), visible.width / deviceSize.width,
        (visible.height - chrome) / deviceSize.height)
      let size = CGSize(width: deviceSize.width * scale, height: deviceSize.height * scale + chrome)
      var frame = CGRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2, width: size.width, height: size.height)
      frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
      frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
      window.setFrame(frame, display: true)
    }
    layer?.contents = image
    lastImage = image
  }

  /// Turns the virtual device by `degrees` around the screen normal; the guest reorients like a real phone.
  func rotate(by degrees: Int32) {
    angle = (angle + degrees + 360) % 360
    inputs.yield(MiniMsg.encode(MiniMsg.rotate, angle))
  }

  func saveScreenshot() {
    guard let image = lastImage else { return }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(name) \(stamp).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    if CGImageDestinationFinalize(dest) { NSSound(named: "Grab")?.play() }
  }

  /// A click captures the Mac pointer, which then drives the guest's virtio mouse until ⌃⌥ gives it back. Android has
  /// no absolute mouse (a tablet device is taken for a touchpad), so the two pointers can't simply track each other.
  var mouseMode = false {
    didSet {
      if !mouseMode { capture(false) }
      updateTitle()
    }
  }
  private var captured = false
  private var buttons: Int32 = 0  // held mouse buttons, bit n for NSEvent.buttonNumber n
  private var motion = CGPoint.zero, wheelRest: CGFloat = 0  // what didn't add up to a whole pixel or notch yet

  private func updateTitle() {
    window?.subtitle = captured ? "Mouse captured, press ⌃⌥ to release" : mouseMode ? "Click to capture the mouse" : ""
  }

  func capture(_ on: Bool) {
    guard on != captured else { return }
    captured = on
    CGAssociateMouseAndMouseCursorPosition(on ? 0 : 1)
    if on {
      NSCursor.hide()
    } else {
      NSCursor.unhide()
      if buttons != 0 {
        buttons = 0
        pointer(nil)
      }
    }
    updateTitle()
  }

  private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

  /// A point in the view → panel pixels.
  private func panel(_ p: CGPoint) -> (x: Int32, y: Int32) {
    // (u, v): position in the displayed (rotated, letterboxed) frame, 0...1 from its top-left corner.
    // Clamped so a drag that leaves the frame pins to its edge instead of jumping.
    let r = imageRect
    let u = min(max((p.x - r.minX) / r.width, 0), 1), v = min(max(1 - (p.y - r.minY) / r.height, 0), 1)
    let panel = Self.panelPoint(u: u, v: v, displayed: deviceSize, rotation: rotation)
    return (Int32(panel.x.rounded()), Int32(panel.y.rounded()))
  }

  /// Fingers: 0 is the click, 1 a trackpad scroll, 2 and 3 a pinch.
  private func touch(_ finger: Int8, at p: CGPoint, down: Bool) {
    let (x, y) = panel(p)
    inputs.yield(MiniMsg.encode(MiniMsg.touch, x, y, down ? 1 : 0, arg: finger))
  }

  /// `e`'s motion, in whole pixels, and the held buttons.
  private func pointer(_ e: NSEvent?, wheel: Int8 = 0) {
    motion.x += e?.deltaX ?? 0
    motion.y += e?.deltaY ?? 0
    let dx = motion.x.rounded(.towardZero), dy = motion.y.rounded(.towardZero)
    motion.x -= dx
    motion.y -= dy
    inputs.yield(MiniMsg.encode(MiniMsg.pointer, Int32(dx), Int32(dy), buttons, arg: wheel))
  }

  private func button(_ e: NSEvent, down: Bool) {
    guard captured else {
      if mouseMode {
        if down && e.buttonNumber == 0 { capture(true) }  // the capturing click isn't the guest's
      } else if e.buttonNumber == 0 {
        touch(0, at: point(e), down: down)
      }
      return
    }
    guard e.buttonNumber < 5 else { return }  // the mouse has left, right, middle, side and extra
    buttons = down ? buttons | 1 << e.buttonNumber : buttons & ~(1 << e.buttonNumber)
    pointer(e)
  }

  /// Mouse wheel lines → notches, at least one per event so slow ticks still scroll.
  nonisolated static func notches(_ lines: CGFloat) -> Int8 { Int8(clamping: Int(lines.rounded(.awayFromZero))) }

  private var scrollFinger: CGPoint?
  private var wheelLift: Task<Void, Never>?

  override func scrollWheel(with e: NSEvent) {
    if captured {
      // The mouse has no horizontal wheel. A trackpad's points add up to notches; a wheel is at least one per event.
      wheelRest = e.hasPreciseScrollingDeltas ? wheelRest + e.scrollingDeltaY / 10 : CGFloat(Self.notches(e.scrollingDeltaY))
      let n = wheelRest.rounded(.towardZero)
      wheelRest -= n
      if n != 0 { pointer(nil, wheel: Int8(clamping: Int(n))) }
      return
    }
    guard e.hasPreciseScrollingDeltas else {
      // A mouse wheel drags a finger a notch at a time, and lifts it once the wheel has rested long enough that
      // Android sees no speed to fling with.
      guard e.scrollingDeltaY != 0 else { return }
      if scrollFinger == nil {
        scrollFinger = point(e)
        touch(1, at: scrollFinger!, down: true)
      }
      let r = imageRect
      var p = scrollFinger!
      // shortcut: a finger that reaches the frame's edge stops there until the wheel rests; restart it if that bites.
      p.y = min(max(p.y - CGFloat(Self.notches(e.scrollingDeltaY)) * r.height / 15, r.minY), r.maxY)
      touch(1, at: p, down: true)
      scrollFinger = p
      wheelLift?.cancel()
      wheelLift = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, let self, let p = self.scrollFinger else { return }
        self.touch(1, at: p, down: false)
        self.scrollFinger = nil
      }
      return
    }
    // A trackpad drags one finger along with the content. Momentum events find no finger and are dropped: Android
    // flings on its own from the release speed.
    if e.phase.contains(.began) { scrollFinger = point(e) }
    guard var p = scrollFinger else { return }
    let r = imageRect
    p.x = min(max(p.x + e.scrollingDeltaX, r.minX), r.maxX)  // pinned inside, so turning back moves it at once
    p.y = min(max(p.y - e.scrollingDeltaY, r.minY), r.maxY)
    let up = e.phase.contains(.ended) || e.phase.contains(.cancelled)
    touch(1, at: p, down: !up)
    scrollFinger = up ? nil : p
  }

  private var pinch: (center: CGPoint, scale: CGFloat)?

  /// Two fingers either side of the cursor, 100 points apart at the start.
  // shortcut: a finger that reaches the frame's edge stops there, capping one pinch's zoom; offset the centre if it bites.
  override func magnify(with e: NSEvent) {
    if e.phase.contains(.began) && !captured { pinch = (point(e), 1) }
    guard var g = pinch else { return }
    g.scale = max(g.scale * (1 + e.magnification), 0.1)
    let up = e.phase.contains(.ended) || e.phase.contains(.cancelled)
    for (finger, side) in [(Int8(2), -1.0), (3, 1.0)] {
      touch(finger, at: CGPoint(x: g.center.x + side * 50 * g.scale, y: g.center.y), down: !up)
    }
    pinch = up ? nil : g
  }

  /// Touches are in the unrotated panel's pixels, so undo the frame's rotation.
  /// (u, v) is the point in the displayed frame, 0...1 from its top-left; `displayed` is that frame's pixel size.
  nonisolated static func panelPoint(
    u: CGFloat, v: CGFloat, displayed: CGSize, rotation: Rotation
  ) -> CGPoint {
    let swapped = CGSize(width: displayed.height, height: displayed.width)
    switch rotation {
    case .landscape: return CGPoint(x: (1 - v) * swapped.width, y: u * swapped.height)  // panel top edge on the left
    case .reverseLandscape: return CGPoint(x: v * swapped.width, y: (1 - u) * swapped.height)
    case .reversePortrait: return CGPoint(x: (1 - u) * displayed.width, y: (1 - v) * displayed.height)
    case .portrait: return CGPoint(x: u * displayed.width, y: v * displayed.height)
    }
  }

  override func mouseDown(with e: NSEvent) { button(e, down: true) }
  override func mouseDragged(with e: NSEvent) {
    if captured { pointer(e) } else if !mouseMode { touch(0, at: point(e), down: true) }
  }
  override func mouseUp(with e: NSEvent) { button(e, down: false) }
  override func mouseMoved(with e: NSEvent) { if captured { pointer(e) } }
  override func rightMouseDown(with e: NSEvent) { button(e, down: true) }
  override func rightMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
  override func rightMouseUp(with e: NSEvent) { button(e, down: false) }
  override func otherMouseDown(with e: NSEvent) { button(e, down: true) }
  override func otherMouseDragged(with e: NSEvent) { mouseMoved(with: e) }
  override func otherMouseUp(with e: NSEvent) { button(e, down: false) }

  private var padState = Gamepad.rest

  /// The pad's whole state; only what changed goes to the guest's virtio-gamepad, in one batch.
  func pad(_ events: [Gamepad.Event]) {
    let changed = zip(events, padState).filter { $0.value != $1.value }.map(\.0)
    padState = events
    guard !changed.isEmpty else { return }
    inputs.yield((changed + [Gamepad.syn]).reduce(into: Data()) { $0 += MiniMsg.encode(MiniMsg.pad, $1.code, $1.value, arg: $1.type) })
  }

  /// W3C key name, e.g. "GoBack", "GoHome", "AppSwitch", "Power", "AudioVolumeUp".
  func named(_ name: String) {
    if name == "AppSwitch" {
      // KEY_APPSELECT has no QEMU key code, so the virtio keyboard can't send it.
      Task { [guest] in await GuestSetup.adb(["-s", guest.serial, "shell", "input keyevent KEYCODE_APP_SWITCH"]) }
      return
    }
    guard let code = MiniMsg.named[name] else { return }
    inputs.yield(MiniMsg.encode(MiniMsg.key, code, 1))
    inputs.yield(MiniMsg.encode(MiniMsg.key, code, 0))
  }

  private func raw(_ e: NSEvent, down: Bool) { inputs.yield(MiniMsg.encode(MiniMsg.macKey, Int32(e.keyCode), down ? 1 : 0)) }

  // ⌘ combinations are Mini's (the Device menu handles them before they get here); everything else goes to the guest.
  override func keyDown(with e: NSEvent) {
    if e.modifierFlags.contains(.command) { super.keyDown(with: e) } else { raw(e, down: true) }
  }

  override func keyUp(with e: NSEvent) {
    if !e.modifierFlags.contains(.command) { raw(e, down: false) }
  }

  /// Modifier keys never reach keyDown/keyUp; AppKit reports them here. Each side has its own device bit (IOKit's
  /// NX_DEVICE*KEYMASK), so letting go of one Shift while holding the other stays correct. ⌘ isn't forwarded: it's Mini's.
  override func flagsChanged(with e: NSEvent) {
    let side: [UInt16: UInt] = [56: 0x2, 60: 0x4, 59: 0x1, 62: 0x2000, 58: 0x20, 61: 0x40]  // ⇧ ⇧ ⌃ ⌃ ⌥ ⌥, left then right
    if let bit = side[e.keyCode] {
      raw(e, down: e.modifierFlags.rawValue & bit != 0)
      if captured && e.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] { capture(false) }
    } else if e.keyCode == 57 {  // Caps Lock: one event per toggle, which the guest toggles on a full press
      raw(e, down: true)
      raw(e, down: false)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ note: Notification) {
    Gamepad.start()
    let begin = {
      DevicesWindow.show()
      guard let avd = flag("--start") else { return }
      do {
        try Machine.start(avd, headless: CommandLine.arguments.contains("--headless"), port: flag("--port").flatMap(Int.init))
      } catch {
        NSAlert(error: error).runModal()
      }
    }
    if PlatformTools.installed { begin() } else { SetupWindow.show(done: begin) }
  }

  @objc func showSettings(_ sender: Any?) { SettingsWindow.show() }
  @objc func showDevices(_ sender: Any?) { DevicesWindow.show() }
  /// A device window's Machine answers first with its own log; from anywhere else, the folder of them.
  @objc func showLog(_ sender: Any?) { NSWorkspace.shared.open(Machine.log("").deletingLastPathComponent()) }

  /// Every device shuts down cleanly, at once; QEMU itself would just pull the plug on /data. Then Mini's adb server goes.
  func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
    let machines = Array(Fleet.shared.machines.values)
    guard !machines.isEmpty || GuestSetup.startedServer else { return .terminateNow }
    Task {
      await withTaskGroup(of: Void.self) { group in for m in machines { group.addTask { await m.stop() } } }
      if GuestSetup.startedServer { await GuestSetup.adb(["kill-server"]) }
      app.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Mini stays open with no windows, like other Mac apps; the Dock icon brings Devices back.
  func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { DevicesWindow.show() }
    return true
  }
}

Prefs.register()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
// nil targets go up the responder chain to the app delegate.
appItem.submenu!.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
appItem.submenu!.addItem(withTitle: "Devices…", action: #selector(AppDelegate.showDevices(_:)), keyEquivalent: "D")
appItem.submenu!.addItem(withTitle: "Show Log", action: #selector(Machine.showLog(_:)), keyEquivalent: "l")
appItem.submenu!.addItem(.separator())
appItem.submenu!.addItem(withTitle: "Quit Mini", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(appItem)
Machine.menus().forEach(menu.addItem)
app.mainMenu = menu
let delegate = AppDelegate()
app.delegate = delegate
// Route SIGTERM/SIGINT through normal termination so no QEMU child is orphaned.
let signalSources = [SIGTERM, SIGINT].map { sig in
  signal(sig, SIG_IGN)
  let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
  // Off the main queue: terminate's .terminateLater loop would otherwise hold it, and the shutdown Tasks need it.
  src.setEventHandler { RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } } }
  src.resume()
  return src
}
app.activate()
app.run()
