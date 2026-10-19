import AppKit
import CShm
import GRPCCore
import GRPCNIOTransportHTTP2

typealias EC = Android_Emulation_Control_EmulatorController
typealias InputEvent = Android_Emulation_Control_InputEvent
typealias KeyEvent = Android_Emulation_Control_KeyboardEvent
typealias PhysicalModel = Android_Emulation_Control_PhysicalModelValue

/// `--start <avd>` boots that device (Devices → Start relaunches Mini with it); without it Mini opens Devices.
let avd = CommandLine.arguments.firstIndex(of: "--start").flatMap { CommandLine.arguments.dropFirst($0 + 1).first } ?? ""
let grpcPort = 8554

/// Memory the emulator (ImageTransport.MMAP, a file) or QEMU (`shared`: POSIX shared memory) writes RGBA frames into.
/// QEMU gets shared memory because a mapped file is written back to disk: hundreds of MB/s at 60 frames a second.
final class FrameBuffer: @unchecked Sendable {
  let path: String
  let ptr: UnsafeMutableRawPointer
  let size: Int
  private let shared: Bool

  init(maxSide: Int, count: Int = 1, shared: Bool = false) throws {
    size = maxSide * maxSide * 4 * count  // square bound so rotation never overflows
    self.shared = shared
    path = shared ? "/mini-\(getpid())" : NSTemporaryDirectory() + "mini-\(getpid()).fb"
    if shared { shm_unlink(path) }  // a leftover from a crashed run would refuse ftruncate
    let fd = shared ? mini_shm_open(path, O_RDWR | O_CREAT | O_EXCL, 0o600) : open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0, ftruncate(fd, off_t(size)) == 0,
      let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), p != MAP_FAILED
    else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    close(fd)
    ptr = p
  }

  /// Drops the name once the other side has mapped it; the memory lives on until both unmap.
  func unlinkName() { _ = shared ? shm_unlink(path) : unlink(path) }

  deinit { munmap(ptr, size); unlinkName() }

  // shortcut: the emulator may write while we read, so frames can tear; upgrade to double-buffered shm if visible.
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
  let inputs: AsyncStream<InputEvent>.Continuation
  let rotations: AsyncStream<PhysicalModel>.Continuation
  private var lastImage: CGImage?
  private var angle: Float = 0

  init(inputs: AsyncStream<InputEvent>.Continuation, rotations: AsyncStream<PhysicalModel>.Continuation) {
    self.inputs = inputs
    self.rotations = rotations
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

  /// Shown until the guest posts its first frame.
  private let spinner = NSProgressIndicator()

  /// Where the letterboxed frame sits inside the view.
  private var imageRect: CGRect {
    let s = min(bounds.width / deviceSize.width, bounds.height / deviceSize.height)
    let size = CGSize(width: deviceSize.width * s, height: deviceSize.height * s)
    return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
  }
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // a tap on an inactive window still taps

  private var rotation = Android_Emulation_Control_Rotation.SkinRotation.portrait

  func show(_ image: CGImage, rotation: Android_Emulation_Control_Rotation.SkinRotation) {
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
  func rotate(by degrees: Float) {
    angle = (angle + degrees + 360).truncatingRemainder(dividingBy: 360)
    var m = PhysicalModel()
    m.target = .rotation
    m.value.data = [0, 0, angle]
    rotations.yield(m)
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
    var t = Android_Emulation_Control_Touch()
    t.x = Int32(panel.x.rounded())
    t.y = Int32(panel.y.rounded())
    t.pressure = down ? 1 : 0
    var ev = InputEvent()
    ev.touchEvent.touches = [t]
    inputs.yield(ev)
  }

  /// Touches are in the unrotated panel's pixels, so undo the frame's rotation.
  /// (u, v) is the point in the displayed frame, 0...1 from its top-left; `displayed` is that frame's pixel size.
  nonisolated static func panelPoint(
    u: CGFloat, v: CGFloat, displayed: CGSize, rotation: Android_Emulation_Control_Rotation.SkinRotation
  ) -> CGPoint {
    let swapped = CGSize(width: displayed.height, height: displayed.width)
    switch rotation {
    case .landscape: return CGPoint(x: (1 - v) * swapped.width, y: u * swapped.height)  // panel top edge on the left
    case .reverseLandscape: return CGPoint(x: v * swapped.width, y: (1 - u) * swapped.height)
    case .reversePortrait: return CGPoint(x: (1 - u) * displayed.width, y: (1 - v) * displayed.height)
    default: return CGPoint(x: u * displayed.width, y: v * displayed.height)
    }
  }

  override func mouseDown(with e: NSEvent) { touch(e, down: true) }
  override func mouseDragged(with e: NSEvent) { touch(e, down: true) }
  override func mouseUp(with e: NSEvent) { touch(e, down: false) }

  private func key(_ k: KeyEvent) {
    var ev = InputEvent()
    ev.keyEvent = k
    inputs.yield(ev)
  }

  /// W3C key name, e.g. "GoBack", "GoHome", "AppSwitch", "Power", "AudioVolumeUp".
  func named(_ name: String) {
    var k = KeyEvent()
    k.eventType = .keypress
    k.key = name
    key(k)
  }

  private func raw(_ e: NSEvent, _ type: KeyEvent.KeyEventType) {
    var k = KeyEvent()
    k.eventType = type
    // kVK_ANSI_A is 0, which proto3 can't tell from "unset", so the emulator drops it; send evdev KEY_A instead.
    (k.codeType, k.keyCode) = e.keyCode == 0 ? (.evdev, 30) : (.mac, Int32(e.keyCode))
    key(k)
  }

  override func keyDown(with e: NSEvent) {
    let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
    switch (mods, e.charactersIgnoringModifiers?.lowercased()) {
    case ([.command, .shift], "h"): named("GoHome")
    case (.command, "\u{7f}"): named("GoBack")  // ⌘⌫
    case (.command, "p"): named("Power")
    case (.command, "o"): named("AppSwitch")
    case (let m, _) where m.contains(.command): super.keyDown(with: e)  // menu shortcuts (⌘Q)
    default: raw(e, .keydown)
    }
  }

  override func keyUp(with e: NSEvent) {
    if !e.modifierFlags.contains(.command) { raw(e, .keyup) }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let emulator = Process()  // or QEMU, for devices on Mini's own engine
  var qemu = false
  var window: NSWindow!
  var quitting = false
  var buttonActions: [() -> Void] = []
  let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mini/\(avd).log")

  func applicationDidFinishLaunching(_ note: Notification) {
    let begin: () -> Void = { [weak self] in if Prefs.avds().contains(avd) { self?.start() } else { DevicesWindow.show() } }
    let onQemu = DeviceConfig.load(avd: avd)?.engine == .qemu
    if EmulatorSetup.installed || onQemu { begin() } else { SetupWindow.show(done: begin) }
  }

  private func start() {
    Devices.running = avd
    let config = DeviceConfig.load(avd: avd)
    qemu = config?.engine == .qemu
    try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.createFile(atPath: logURL.path, contents: nil), let log = try? FileHandle(forWritingTo: logURL) {
      emulator.standardOutput = log
      emulator.standardError = log
    }
    emulator.terminationHandler = { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
    let fb: FrameBuffer?
    let socketPath = NSTemporaryDirectory() + "mini-\(getpid()).sock"
    if qemu, let config {
      do {
        let side = max(config.size.width, config.size.height)
        fb = try FrameBuffer(maxSide: side, count: 2, shared: true)
        emulator.executableURL = URL(fileURLWithPath: Qemu.binary)
        emulator.environment = ProcessInfo.processInfo.environment.merging(["ANDROID_EMU_VK_ICD": "moltenvk"]) { _, new in new }
        emulator.arguments = try Qemu.arguments(
          avd: avd, socket: socketPath, shm: fb!.path, log: logURL.deletingPathExtension().path)
        try emulator.run()
      } catch { fatal("cannot launch QEMU: \(error.localizedDescription)") }
      Task.detached { await GuestSetup.afterBoot(refreshHz: config.refreshHz) }
      let profile = URL(fileURLWithPath: (Prefs.configPath(avd: avd) as NSString).deletingLastPathComponent)
        .appendingPathComponent("modem_simulator/iccprofile_for_sim0.xml")
      Task.detached { try? await Modem.run(socket: socketPath + ".modem", profile: profile) }
    } else {
      fb = nil
      launchEmulator()
    }
    showWindow(fb: fb, socketPath: socketPath)
  }

  private func launchEmulator() {
    emulator.executableURL = URL(fileURLWithPath: EmulatorSetup.dir + "/emulator")
    // Mini's emulator lives outside the SDK; it still needs the SDK for system images.
    // Canary defaults to KosmicKrisp; force MoltenVK (Mini's private-API build has provoking_vertex and faster readback).
    emulator.environment = ProcessInfo.processInfo.environment.merging(
      ["ANDROID_SDK_ROOT": Prefs.sdk,
       "ANDROID_EMU_VK_SELECT_ICD": ProcessInfo.processInfo.environment["ANDROID_EMU_VK_SELECT_ICD"] ?? "moltenvk"]) { _, new in new }
    emulator.arguments = Prefs.emulatorArgs(avd: avd, grpcPort: grpcPort)
    do { try emulator.run() } catch { fatal("cannot launch emulator: \(error)") }
    liftRefreshCap()
  }

  private func showWindow(fb: FrameBuffer?, socketPath: String) {
    let (inputs, inputsCont) = AsyncStream.makeStream(of: InputEvent.self)
    let (rotations, rotationsCont) = AsyncStream.makeStream(of: PhysicalModel.self)
    let view = ScreenView(inputs: inputsCont, rotations: rotationsCont)
    let screenH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
    window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: screenH * 9 / 20, height: screenH),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = avd
    window.titleVisibility = .hidden  // the soft buttons need the room
    window.contentView = view
    addSoftButtons(for: view)
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)

    Task.detached { [weak view, weak self] in
      let onFrame: @Sendable (CGImage, Android_Emulation_Control_Rotation.SkinRotation) async -> Void = { img, rot in
        await MainActor.run { view?.show(img, rotation: rot) }
      }
      do {
        if let fb {
          try await Self.runQemu(fb: fb, socket: socketPath, inputs: inputs, rotations: rotations, onFrame: onFrame)
        } else {
          try await Self.run(inputs: inputs, rotations: rotations, onFrame: onFrame)
        }
      } catch {
        // The stream always dies while we shut the emulator down; only alert on unexpected failures.
        await MainActor.run { if self?.quitting == false { fatal("\(fb == nil ? "gRPC" : "QEMU display"): \(error)") } }
      }
    }
  }

  private func addSoftButtons(for view: ScreenView) {
    let buttons: [(symbol: String, label: String, action: () -> Void)] = [
      ("chevron.backward", "Back", { view.named("GoBack") }),
      ("circle", "Home", { view.named("GoHome") }),
      ("square", "Overview", { view.named("AppSwitch") }),
      ("rotate.left", "Rotate left", { view.rotate(by: 90) }),
      ("rotate.right", "Rotate right", { view.rotate(by: -90) }),
      ("speaker.wave.1", "Volume down", { view.named("AudioVolumeDown") }),
      ("speaker.wave.3", "Volume up", { view.named("AudioVolumeUp") }),
      ("power", "Power", { view.named("Power") }),
      ("camera", "Screenshot to Desktop", { view.saveScreenshot() }),
    ]
    buttonActions = buttons.map(\.action)
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

  /// Android's default-refresh-rate vote holds rendering at 60 Hz even when hw.lcd.vsync offers more; a user
  /// minimum outranks it. Needs adb, so a guest whose adbd doesn't answer (some GSIs) stays at 60.
  private func liftRefreshCap() {
    guard let hz = DeviceConfig.load(avd: avd)?.refreshHz, hz > 60 else { return }
    let adb = Process()
    adb.executableURL = URL(fileURLWithPath: Prefs.sdk + "/platform-tools/adb")
    // shortcut: assumes Mini's emulator is the only one (console port 5554); pass -port if you run several.
    adb.arguments = ["-s", "emulator-5554", "wait-for-device", "shell",
                     "until [ \"$(getprop sys.boot_completed)\" = 1 ]; do sleep 1; done; settings put system min_refresh_rate \(hz)"]
    adb.standardOutput = FileHandle.nullDevice
    adb.standardError = FileHandle.nullDevice
    try? adb.run()
  }

  @objc func softButton(_ sender: NSButton) { buttonActions[sender.tag]() }
  @objc func showSettings(_ sender: Any?) { SettingsWindow.show() }
  @objc func showDevices(_ sender: Any?) { DevicesWindow.show() }
  @objc func showLog(_ sender: Any?) { NSWorkspace.shared.open(logURL) }

  nonisolated static func run(
    inputs: AsyncStream<InputEvent>, rotations: AsyncStream<PhysicalModel>,
    onFrame: @escaping @Sendable (CGImage, Android_Emulation_Control_Rotation.SkinRotation) async -> Void
  ) async throws {
    try await withGRPCClient(
      transport: .http2NIOPosix(target: .ipv4(address: "127.0.0.1", port: grpcPort), transportSecurity: .plaintext)
    ) { client in
      let ec = EC.Client(wrapping: client)
      var opts = CallOptions.defaults
      // One full RGBA frame is ~10 MB. The NIO transport sizes its response decoder from the *request* limit.
      opts.maxResponseMessageBytes = 64 << 20
      opts.maxRequestMessageBytes = 64 << 20

      // Discovery file and gRPC server appear a moment after launch; probe until a screenshot works.
      var md: Metadata = [:]
      var first: Android_Emulation_Control_Image?
      while first == nil {
        if let token = grpcToken() {
          md = ["authorization": "Bearer \(token)"]
          var f = Android_Emulation_Control_ImageFormat()
          f.format = .rgba8888
          do { first = try await ec.getScreenshot(f, metadata: md, options: opts) } catch {
            FileHandle.standardError.write(Data("waiting for emulator: \(error)\n".utf8))
          }
        }
        if first == nil { try await Task.sleep(for: .seconds(1)) }
      }

      let fb = try FrameBuffer(maxSide: Int(max(first!.format.width, first!.format.height)))
      var fmt = Android_Emulation_Control_ImageFormat()
      fmt.format = .rgba8888
      fmt.transport.channel = .mmap
      fmt.transport.handle = "file://" + fb.path

      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { [md] in
          _ = try await ec.streamInputEvent(metadata: md) { writer in
            for await ev in inputs { try await writer.write(ev) }
          }
        }
        group.addTask { [md] in
          for await m in rotations { _ = try await ec.setPhysicalModel(m, metadata: md) }
        }
        group.addTask { [md, fmt] in
          try await ec.streamScreenshot(fmt, metadata: md) { response in
            for try await img in response.messages {
              if let cg = fb.image(width: Int(img.format.width), height: Int(img.format.height)) {
                await onFrame(cg, img.format.rotation.rotation)
              }
            }
          }
        }
        try await group.next()
        group.cancelAll()
      }
    }
  }

  /// Frames and input through QEMU's mini-display object (third_party/qemu/ui/mini.c).
  nonisolated static func runQemu(
    fb: FrameBuffer, socket path: String, inputs: AsyncStream<InputEvent>, rotations: AsyncStream<PhysicalModel>,
    onFrame: @escaping @Sendable (CGImage, Android_Emulation_Control_Rotation.SkinRotation) async -> Void
  ) async throws {
    let link = try await Qemu.connect(path)
    fb.unlinkName()  // QEMU mapped it before it took connections; nothing is left behind if Mini dies
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        for await ev in inputs { for msg in MiniMsg.encode(ev) { try link.write(contentsOf: msg) } }
      }
      group.addTask {
        for await m in rotations { try link.write(contentsOf: MiniMsg.encode(MiniMsg.rotate, Int32(m.value.data[2]))) }
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
            await onFrame(cg, .init(rawValue: f[2]) ?? .portrait)
          }
        }
      }
      try await group.next()
      group.cancelAll()
    }
  }

  func applicationWillTerminate(_ note: Notification) {
    quitting = true
    guard emulator.isRunning else { return }
    emulator.terminationHandler = nil
    if qemu {
      // Android shuts down and powers the VM off; QEMU itself would just pull the plug on /data.
      let asked = DispatchSemaphore(value: 0)
      Task.detached { _ = await GuestSetup.powerOff(); asked.signal() }
      _ = asked.wait(timeout: .now() + 5)
      for _ in 0..<150 where emulator.isRunning { usleep(100_000) }
      if !emulator.isRunning { return }
    }
    emulator.terminate()  // SIGTERM: the emulator saves its quick-boot snapshot and exits
    emulator.waitUntilExit()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

/// `grpc.token` from the emulator discovery file (`avd/running/pid_*.ini`) that serves our port.
func grpcToken() -> String? {
  let dir = NSHomeDirectory() + "/Library/Caches/TemporaryItems/avd/running/"
  for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
    guard let ini = try? String(contentsOfFile: dir + name, encoding: .utf8) else { continue }
    let kv = Dictionary(ini.split(separator: "\n").compactMap { line -> (String, String)? in
      guard let eq = line.firstIndex(of: "=") else { return nil }
      return (String(line[..<eq]), String(line[line.index(after: eq)...]))
    }, uniquingKeysWith: { a, _ in a })
    if kv["grpc.port"] == "\(grpcPort)", let token = kv["grpc.token"] { return token }
  }
  return nil
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
appItem.submenu!.addItem(withTitle: "Show Emulator Log", action: #selector(AppDelegate.showLog(_:)), keyEquivalent: "l")
appItem.submenu!.addItem(.separator())
appItem.submenu!.addItem(withTitle: "Quit Mini", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(appItem)
app.mainMenu = menu
let delegate = AppDelegate()
app.delegate = delegate
// Route SIGTERM/SIGINT through normal termination so the emulator child is never orphaned.
let signalSources = [SIGTERM, SIGINT].map { sig in
  signal(sig, SIG_IGN)
  let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
  src.setEventHandler { NSApp.terminate(nil) }
  src.resume()
  return src
}
app.activate()
app.run()
