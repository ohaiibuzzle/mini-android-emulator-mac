import AppKit
import Observation

/// The devices Mini is running, by name. The Devices window lists them.
@MainActor @Observable
final class Fleet {
  static let shared = Fleet()
  var machines: [String: Machine] = [:]
  /// Why a device's last run ended, when nobody asked it to.
  var failures: [String: String] = [:]
}

/// One running device: its QEMU, the host ends of its modem and Bluetooth, and its window unless it runs headless.
@MainActor @Observable
final class Machine: NSObject, NSWindowDelegate {
  enum State: String { case booting = "Booting", running = "Running", stopping = "Shutting down" }

  let name: String
  /// The emulator's console port; QEMU takes adb on the next one.
  let port: Int
  let guest: GuestSetup
  private(set) var state = State.booting
  private(set) var window: NSWindow?
  @ObservationIgnored private let qemu = Process()
  @ObservationIgnored private var fb: FrameBuffer!
  @ObservationIgnored private let socket: String
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var exited = false
  @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

  static func log(_ name: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mini/\(name).log")
  }

  /// Boots `name` with a window, or without for scrcpy and the like over adb. `port` is its console port, as the
  /// emulator's -port takes it; by default the lowest free pair in what adb scans for emulators (5554...5585).
  @discardableResult
  static func start(_ name: String, headless: Bool, port: Int? = nil) throws -> Machine {
    let fleet = Fleet.shared
    guard fleet.machines[name] == nil else { throw SetupError("\(name) is already running") }
    let free = { (p: Int) in !fleet.machines.values.contains { $0.port == p } && Qemu.canListen(p) && Qemu.canListen(p + 1) }
    if let port, port % 2 != 0 || !(1024...65534).contains(port) { throw SetupError("--port takes an even port from 1024 to 65534") }
    if let port, !free(port) { throw SetupError("port \(port) or \(port + 1) is in use") }
    guard let port = port ?? stride(from: 5554, through: 5584, by: 2).first(where: free) else {
      throw SetupError("no free adb port: adb finds at most 16 emulators")
    }
    let m = Machine(name: name, port: port)
    try m.boot(headless: headless)
    fleet.machines[name] = m
    fleet.failures[name] = nil
    UserDefaults.standard.set(name, forKey: Prefs.avd)
    if !headless { m.showWindow() }
    return m
  }

  private init(name: String, port: Int) {
    self.name = name
    self.port = port
    guest = GuestSetup(adbPort: port + 1)
    socket = NSTemporaryDirectory() + "mini-\(getpid())-\(port).sock"
  }

  private func boot(headless: Bool) throws {
    guard let config = DeviceConfig.load(avd: name) else { throw SetupError("cannot read \(Prefs.configPath(avd: name))") }
    let log = Self.log(name)
    try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.createFile(atPath: log.path, contents: nil), let h = try? FileHandle(forWritingTo: log) {
      qemu.standardOutput = h
      qemu.standardError = h
    }
    qemu.terminationHandler = { [weak self] p in
      let status = p.terminationStatus
      Task { @MainActor in self?.qemuExited(status: status) }
    }
    fb = try FrameBuffer(maxSide: max(config.size.width, config.size.height), count: 2, name: "/mini-\(getpid())-\(port)")
    qemu.executableURL = URL(fileURLWithPath: Qemu.binary)
    qemu.environment = Qemu.environment(hostGLES: config.hostGLES && Qemu.hostGLESAvailable)
    qemu.arguments = try Qemu.arguments(
      avd: name, adbPort: guest.adbPort, socket: socket, shm: fb.path, log: log.deletingPathExtension().path)
    try qemu.run()
    let profile = URL(fileURLWithPath: Prefs.home + "/" + config.sysdir + "data/misc/modem_simulator/iccprofile_for_sim0.xml")
    tasks = [
      Task.detached { [guest, weak self] in
        guard await guest.waitForBoot() else { return }
        await self?.booted()
        await guest.afterBoot(refreshHz: config.refreshHz)
      },
      Task.detached { [socket] in try? await Modem.run(socket: socket + ".modem", profile: profile) },
      Task.detached { [socket] in try? await Bluetooth.run(socket: socket + ".bluetooth") },
    ]
    if headless {
      // The socket answers only once QEMU has mapped the shm; then the name can go, and hanging up stops the frame copies.
      tasks.append(Task.detached { [socket, fb] in if (try? await Qemu.connect(socket)) != nil { fb?.unlinkName() } })
    }
  }

  private func booted() { if state == .booting { state = .running } }

  /// Opens the device's screen; mini-display starts sending frames once it connects.
  func showWindow() {
    if let window { return window.makeKeyAndOrderFront(nil) }
    let (inputs, inputsCont) = AsyncStream.makeStream(of: Data.self)
    let view = ScreenView(name: name, guest: guest, inputs: inputsCont)
    let screenH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
    let w = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: screenH * 9 / 20, height: screenH),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false  // Machine holds it
    w.title = name
    w.contentView = view
    w.delegate = self
    let toolbar = NSToolbar(identifier: "device")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    w.toolbar = toolbar
    w.toolbarStyle = .unified  // the title left-aligned, the mouse hint under it as the subtitle
    w.center()
    w.makeKeyAndOrderFront(nil)
    w.makeFirstResponder(view)
    window = w
    if state == .stopping { view.showShuttingDown() }

    let fb = fb!, socket = socket
    tasks.append(Task.detached { [weak view, weak self] in
      do {
        try await Self.runQemu(fb: fb, socket: socket, inputs: inputs) { img, rot in
          await MainActor.run { view?.show(img, rotation: rot) }
        }
      } catch {
        // The link always dies while QEMU shuts down; anything else leaves a screen that can't work, so stop.
        await MainActor.run {
          guard let self, !self.exited, self.state != .stopping else { return }
          Fleet.shared.failures[self.name] = "display: \(error)"
          Task { await self.stop() }
        }
      }
    })
  }

  private var view: ScreenView? { window?.contentView as? ScreenView }

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

  // Shortcuts are the Android Emulator's, so they're what Android developers' fingers already know.
  // The Device menu's buttons, which come first, are also in the toolbar.
  static let buttons: [(menu: String, symbol: String, label: String, key: String, mods: NSEvent.ModifierFlags, action: @MainActor (ScreenView) -> Void)] = {
    let arrow = { (k: Int) in String(Character(UnicodeScalar(k)!)) }
    return [
      ("Device", "chevron.backward", "Back", "\u{8}", .command, { $0.named("GoBack") }),  // ⌘⌫
      ("Device", "circle", "Home", "h", [.command, .shift], { $0.named("GoHome") }),
      ("Device", "square", "Overview", "o", .command, { $0.named("AppSwitch") }),
      ("Device", "power", "Power", "p", .command, { $0.named("Power") }),
      ("View", "rotate.left", "Rotate left", arrow(NSLeftArrowFunctionKey), .command, { $0.rotate(by: 90) }),
      ("View", "rotate.right", "Rotate right", arrow(NSRightArrowFunctionKey), .command, { $0.rotate(by: -90) }),
      ("View", "camera", "Screenshot to Desktop", "s", .command, { $0.saveScreenshot() }),
      ("Audio", "speaker.wave.1", "Volume down", arrow(NSDownArrowFunctionKey), .command, { $0.named("AudioVolumeDown") }),
      ("Audio", "speaker.wave.3", "Volume up", arrow(NSUpArrowFunctionKey), .command, { $0.named("AudioVolumeUp") }),
    ]
  }()

  /// The Device, View and Audio menus (nil target) reach the key window's Machine, as its delegate, through the
  /// responder chain.
  static func menus() -> [NSMenuItem] {
    ["Device", "View", "Audio"].map { title in
      let menu = NSMenu(title: title)
      for (i, b) in buttons.enumerated() where b.menu == title {
        let item = menu.addItem(withTitle: b.label, action: #selector(softButton(_:)), keyEquivalent: b.key)
        item.keyEquivalentModifierMask = b.mods
        item.tag = i
      }
      if title == "Device" {
        menu.addItem(.separator())
        menu.addItem(withTitle: "Mouse Pointer", action: #selector(toggleMouseMode(_:)), keyEquivalent: "M")  // ⌘⇧M
      }
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.submenu = menu
      return item
    }
  }

  @objc func softButton(_ sender: Any) {
    let i = (sender as? NSToolbarItemGroup)?.selectedIndex ?? (sender as! NSMenuItem).tag
    if let view { Self.buttons[i].action(view) }
  }

  @objc func showLog(_ sender: Any?) { NSWorkspace.shared.open(Self.log(name)) }

  /// Per window and not saved: every start is in touch mode.
  @objc func toggleMouseMode(_ sender: Any?) { view?.mouseMode.toggle() }

  /// Android shuts down and powers the VM off, while the window says so; QEMU itself would just pull the plug on /data.
  /// Returns once QEMU has exited.
  func stop() async {
    guard !exited else { return }
    if state != .stopping {
      state = .stopping
      view?.showShuttingDown()
      Task {
        // Its result means nothing: adb reports failure when the shutting-down guest drops the connection.
        _ = await guest.powerOff()
        for _ in 0..<150 where qemu.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if qemu.isRunning { qemu.terminate() }
        for _ in 0..<20 where qemu.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if qemu.isRunning { kill(qemu.processIdentifier, SIGKILL) }
      }
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func qemuExited(status: Int32) {
    exited = true
    tasks.forEach { $0.cancel() }
    // A guest that powers itself off exits 0, like a stop does.
    if state != .stopping, status != 0 {
      Fleet.shared.failures[name] = "QEMU exited with status \(status); see the device's log"
      DevicesWindow.show()
    }
    window?.close()
    window = nil
    Fleet.shared.machines[name] = nil
    waiters.forEach { $0.resume() }
    waiters = []
  }

  /// ⌘-Tab, another window or closing gives the Mac its pointer back, and lets go of the pad.
  func windowDidResignKey(_ note: Notification) {
    view?.capture(false)
    view?.pad(Gamepad.rest)
  }

  /// Full screen is all screen: the toolbar slides in with the menu bar, as the title bar did before it had one.
  func window(
    _ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions = []
  ) -> NSApplication.PresentationOptions { proposed.union(.autoHideToolbar) }

  /// Closing the window stops the device, with the window still there to show it shutting down.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    Task { await stop() }
    return false
  }
}

extension Machine: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(toggleMouseMode(_:)) { item.state = view?.mouseMode == true ? .on : .off }
    return true
  }
}

extension Machine: NSToolbarDelegate {
  private static let softButtons = NSToolbarItem.Identifier("softButtons")

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool
  ) -> NSToolbarItem? {
    let device = Self.buttons.filter { $0.menu == "Device" }
    let group = NSToolbarItemGroup(
      itemIdentifier: id, images: device.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label)! },
      selectionMode: .momentary, labels: device.map(\.label), target: self, action: #selector(softButton(_:)))
    for (item, b) in zip(group.subitems, device) { item.toolTip = b.label }
    return group
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.softButtons] }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
}
