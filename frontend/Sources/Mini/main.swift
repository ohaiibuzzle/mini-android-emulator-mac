import AppKit
import CShm

/// `--start <avd>` boots that device (Devices → Start relaunches Mini with it); without it Mini opens Devices.
let avd = CommandLine.arguments.firstIndex(of: "--start").flatMap { CommandLine.arguments.dropFirst($0 + 1).first } ?? ""

/// Panel orientation in quarter turns counter-clockwise, as mini-display reports it with each frame.
enum Rotation: Int { case portrait, landscape, reversePortrait, reverseLandscape }

/// POSIX shared memory QEMU's mini-display writes RGBA frames into. Not a mapped file: that is written back to disk,
/// hundreds of MB/s at 60 frames a second.
final class FrameBuffer: @unchecked Sendable {
  let path: String
  let ptr: UnsafeMutableRawPointer
  let size: Int

  init(maxSide: Int, count: Int) throws {
    // Square bound so rotation never overflows. Whole pages per frame: macOS rounds shm up to a page, and mini-display
    // splits the rounded size, so an unrounded frame size would shift every frame after the first.
    let page = Int(getpagesize())
    size = (maxSide * maxSide * 4 + page - 1) / page * page * count
    path = "/mini-\(getpid())"
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
  let inputs: AsyncStream<Data>.Continuation  // mini-display messages
  private var lastImage: CGImage?
  private var angle: Int32 = 0

  init(inputs: AsyncStream<Data>.Continuation) {
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
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(avd) \(stamp).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    if CGImageDestinationFinalize(dest) { NSSound(named: "Grab")?.play() }
  }

  private func touch(_ e: NSEvent, down: Bool) {
    let p = convert(e.locationInWindow, from: nil)
    // (u, v): position in the displayed (rotated, letterboxed) frame, 0...1 from its top-left corner.
    // Clamped so a drag that leaves the frame pins to its edge instead of jumping.
    let r = imageRect
    let u = min(max((p.x - r.minX) / r.width, 0), 1), v = min(max(1 - (p.y - r.minY) / r.height, 0), 1)
    let panel = Self.panelPoint(u: u, v: v, displayed: deviceSize, rotation: rotation)
    inputs.yield(MiniMsg.encode(MiniMsg.touch, Int32(panel.x.rounded()), Int32(panel.y.rounded()), down ? 1 : 0))
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

  override func mouseDown(with e: NSEvent) { touch(e, down: true) }
  override func mouseDragged(with e: NSEvent) { touch(e, down: true) }
  override func mouseUp(with e: NSEvent) { touch(e, down: false) }

  /// W3C key name, e.g. "GoBack", "GoHome", "AppSwitch", "Power", "AudioVolumeUp".
  func named(_ name: String) {
    if name == "AppSwitch" {
      // KEY_APPSELECT has no QEMU key code, so the virtio keyboard can't send it.
      Task { await GuestSetup.adb(["-s", GuestSetup.serial, "shell", "input keyevent KEYCODE_APP_SWITCH"]) }
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
    } else if e.keyCode == 57 {  // Caps Lock: one event per toggle, which the guest toggles on a full press
      raw(e, down: true)
      raw(e, down: false)
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let qemu = Process()
  var window: NSWindow!
  var quitting = false
  var buttonActions: [() -> Void] = []
  let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mini/\(avd).log")

  func applicationDidFinishLaunching(_ note: Notification) {
    let begin: () -> Void = { [weak self] in if Prefs.avds().contains(avd) { self?.start() } else { DevicesWindow.show() } }
    if PlatformTools.installed { begin() } else { SetupWindow.show(done: begin) }
  }

  private func start() {
    Devices.running = avd
    guard let config = DeviceConfig.load(avd: avd) else { fatal("cannot read \(Prefs.configPath(avd: avd))") }
    try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.createFile(atPath: logURL.path, contents: nil), let log = try? FileHandle(forWritingTo: logURL) {
      qemu.standardOutput = log
      qemu.standardError = log
    }
    qemu.terminationHandler = { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
    let fb: FrameBuffer
    let socketPath = NSTemporaryDirectory() + "mini-\(getpid()).sock"
    do {
      fb = try FrameBuffer(maxSide: max(config.size.width, config.size.height), count: 2)
      qemu.executableURL = URL(fileURLWithPath: Qemu.binary)
      qemu.environment = Qemu.environment(hostGLES: config.hostGLES && Qemu.hostGLESAvailable)
      qemu.arguments = try Qemu.arguments(avd: avd, socket: socketPath, shm: fb.path, log: logURL.deletingPathExtension().path)
      try qemu.run()
    } catch { fatal("cannot launch QEMU: \(error.localizedDescription)") }
    Task.detached { await GuestSetup.afterBoot(refreshHz: config.refreshHz) }
    let profile = URL(fileURLWithPath: Prefs.home + "/" + config.sysdir + "data/misc/modem_simulator/iccprofile_for_sim0.xml")
    Task.detached { try? await Modem.run(socket: socketPath + ".modem", profile: profile) }
    Task.detached { try? await Bluetooth.run(socket: socketPath + ".bluetooth") }
    showWindow(fb: fb, socketPath: socketPath)
  }

  private func showWindow(fb: FrameBuffer, socketPath: String) {
    let (inputs, inputsCont) = AsyncStream.makeStream(of: Data.self)
    let view = ScreenView(inputs: inputsCont)
    let screenH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
    window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: screenH * 9 / 20, height: screenH),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = avd
    window.titleVisibility = .hidden  // the soft buttons need the room
    window.contentView = view
    window.delegate = self
    addSoftButtons(for: view)
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)

    Task.detached { [weak view, weak self] in
      do {
        try await Self.runQemu(fb: fb, socket: socketPath, inputs: inputs) { img, rot in
          await MainActor.run { view?.show(img, rotation: rot) }
        }
      } catch {
        // The link always dies while we shut QEMU down; only alert on unexpected failures.
        await MainActor.run { if self?.quitting == false { fatal("QEMU display: \(error)") } }
      }
    }
  }

  private func addSoftButtons(for view: ScreenView) {
    // Shortcuts are the Android Emulator's, so they're what Android developers' fingers already know.
    let arrow = { (k: Int) in String(Character(UnicodeScalar(k)!)) }
    let buttons: [(symbol: String, label: String, key: String, mods: NSEvent.ModifierFlags, action: () -> Void)] = [
      ("chevron.backward", "Back", "\u{8}", .command, { view.named("GoBack") }),  // ⌘⌫
      ("circle", "Home", "h", [.command, .shift], { view.named("GoHome") }),
      ("square", "Overview", "o", .command, { view.named("AppSwitch") }),
      ("rotate.left", "Rotate left", arrow(NSLeftArrowFunctionKey), .command, { view.rotate(by: 90) }),
      ("rotate.right", "Rotate right", arrow(NSRightArrowFunctionKey), .command, { view.rotate(by: -90) }),
      ("speaker.wave.1", "Volume down", arrow(NSDownArrowFunctionKey), .command, { view.named("AudioVolumeDown") }),
      ("speaker.wave.3", "Volume up", arrow(NSUpArrowFunctionKey), .command, { view.named("AudioVolumeUp") }),
      ("power", "Power", "p", .command, { view.named("Power") }),
      ("camera", "Screenshot to Desktop", "s", .command, { view.saveScreenshot() }),
    ]
    buttonActions = buttons.map(\.action)
    let deviceMenu = NSMenu(title: "Device")
    for (i, b) in buttons.enumerated() {
      let item = deviceMenu.addItem(withTitle: b.label, action: #selector(softButton(_:)), keyEquivalent: b.key)
      item.keyEquivalentModifierMask = b.mods
      item.target = self
      item.tag = i
    }
    let deviceItem = NSMenuItem(title: "Device", action: nil, keyEquivalent: "")
    deviceItem.submenu = deviceMenu
    NSApp.mainMenu?.addItem(deviceItem)
    let stack = NSStackView(views: buttons.enumerated().map { i, b in
      let button = NSButton(
        image: NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.label)!, target: self,
        action: #selector(softButton(_:)))
      button.isBordered = false
      button.tag = i
      button.toolTip = b.label
      return button
    })
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
    stack.frame.size = stack.fittingSize  // trailing accessories are sized by frame, not constraints
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = stack
    accessory.layoutAttribute = .trailing
    window.addTitlebarAccessoryViewController(accessory)
  }

  @objc func softButton(_ sender: Any) { buttonActions[(sender as? NSButton)?.tag ?? (sender as! NSMenuItem).tag]() }
  @objc func showSettings(_ sender: Any?) { SettingsWindow.show() }
  @objc func showDevices(_ sender: Any?) { DevicesWindow.show() }
  @objc func showLog(_ sender: Any?) { NSWorkspace.shared.open(logURL) }

  /// Frames and input through QEMU's mini-display object (third_party/qemu/ui/mini.c).
  nonisolated static func runQemu(
    fb: FrameBuffer, socket path: String, inputs: AsyncStream<Data>,
    onFrame: @escaping @Sendable (CGImage, Rotation) async -> Void
  ) async throws {
    let link = try await Qemu.connect(path)
    fb.unlinkName()  // QEMU mapped it before it took connections; nothing is left behind if Mini dies
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await msg in inputs { try link.write(contentsOf: msg) }
      }
      group.addTask {
        // FrameMsg: width, height, rotation (quarter turns), which of the two frames.
        var msg: [UInt8] = []
        for try await byte in link.bytes {
          msg.append(byte)
          guard msg.count == 16 else { continue }
          let f = msg.withUnsafeBytes { raw in (0..<4).map { Int(UInt32(littleEndian: raw.load(fromByteOffset: $0 * 4, as: UInt32.self))) } }
          msg.removeAll(keepingCapacity: true)
          if let cg = fb.image(width: f[0], height: f[1], offset: f[3] * fb.size / 2) {
            await onFrame(cg, Rotation(rawValue: f[2]) ?? .portrait)
          }
        }
      }
      try await group.next()
      group.cancelAll()
    }
  }

  /// Android shuts down and powers the VM off while the window says so; QEMU itself would just pull the plug on /data.
  func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
    guard qemu.isRunning, !quitting else { return .terminateNow }
    quitting = true
    qemu.terminationHandler = nil
    (window?.contentView as? ScreenView)?.showShuttingDown()
    Task {
      // Its result means nothing: adb reports failure when the shutting-down guest drops the connection.
      _ = await GuestSetup.powerOff()
      for _ in 0..<150 where qemu.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
      if qemu.isRunning { qemu.terminate() }
      for _ in 0..<20 where qemu.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
      app.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// Closing the window quits through the shutdown above, with the window still there to show it.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NSApp.terminate(nil)
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@MainActor func fatal(_ msg: String) -> Never {
  let a = NSAlert()
  a.messageText = msg
  a.runModal()
  exit(1)
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
appItem.submenu!.addItem(withTitle: "Show Log", action: #selector(AppDelegate.showLog(_:)), keyEquivalent: "l")
appItem.submenu!.addItem(.separator())
appItem.submenu!.addItem(withTitle: "Quit Mini", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(appItem)
app.mainMenu = menu
let delegate = AppDelegate()
app.delegate = delegate
// Route SIGTERM/SIGINT through normal termination so the QEMU child is never orphaned.
let signalSources = [SIGTERM, SIGINT].map { sig in
  signal(sig, SIG_IGN)
  let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
  src.setEventHandler { NSApp.terminate(nil) }
  src.resume()
  return src
}
app.activate()
app.run()
