import AppKit
import GRPCCore
import GRPCNIOTransportHTTP2

typealias EC = Android_Emulation_Control_EmulatorController
typealias InputEvent = Android_Emulation_Control_InputEvent
typealias KeyEvent = Android_Emulation_Control_KeyboardEvent

let avd = CommandLine.arguments.dropFirst().first ?? "goldfish37"
let grpcPort = 8554
let sdk = ProcessInfo.processInfo.environment["ANDROID_HOME"] ?? NSHomeDirectory() + "/Library/Android/sdk"

/// File the emulator writes RGBA frames into (ImageTransport.MMAP); we map the same file.
final class FrameBuffer: @unchecked Sendable {
  let path = NSTemporaryDirectory() + "mini-\(getpid()).fb"
  let ptr: UnsafeMutableRawPointer
  let size: Int

  init(maxSide: Int) throws {
    size = maxSide * maxSide * 4  // square bound so rotation never overflows
    let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
    guard fd >= 0, ftruncate(fd, off_t(size)) == 0,
      let p = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), p != MAP_FAILED
    else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    close(fd)
    ptr = p
  }

  deinit { munmap(ptr, size); unlink(path) }

  // shortcut: the emulator may write while we read, so frames can tear; upgrade to double-buffered shm if visible.
  func image(width: Int, height: Int) -> CGImage? {
    guard width * height * 4 <= size,
      let provider = CGDataProvider(dataInfo: nil, data: ptr, size: width * height * 4, releaseData: { _, _, _ in })
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

  init(inputs: AsyncStream<InputEvent>.Continuation) {
    self.inputs = inputs
    super.init(frame: .zero)
    wantsLayer = true
    layer?.contentsGravity = .resize
    layer?.backgroundColor = .black
  }
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }

  func show(_ image: CGImage) {
    deviceSize = CGSize(width: image.width, height: image.height)
    if let window, window.contentAspectRatio != deviceSize {
      window.contentAspectRatio = deviceSize
      // Rotation: keep the window's height, swap to the new aspect.
      let h = window.contentLayoutRect.height
      window.setContentSize(CGSize(width: h * deviceSize.width / deviceSize.height, height: h))
    }
    layer?.contents = image
  }

  private func touch(_ e: NSEvent, down: Bool) {
    let p = convert(e.locationInWindow, from: nil)
    var t = Android_Emulation_Control_Touch()
    t.x = Int32((p.x / bounds.width * deviceSize.width).rounded())
    t.y = Int32(((1 - p.y / bounds.height) * deviceSize.height).rounded())
    t.pressure = down ? 1 : 0
    var ev = InputEvent()
    ev.touchEvent.touches = [t]
    inputs.yield(ev)
  }

  override func mouseDown(with e: NSEvent) { touch(e, down: true) }
  override func mouseDragged(with e: NSEvent) { touch(e, down: true) }
  override func mouseUp(with e: NSEvent) { touch(e, down: false) }

  private func key(_ k: KeyEvent) {
    var ev = InputEvent()
    ev.keyEvent = k
    inputs.yield(ev)
  }

  private func named(_ name: String) {
    var k = KeyEvent()
    k.eventType = .keypress
    k.key = name
    key(k)
  }

  private func raw(_ e: NSEvent, _ type: KeyEvent.KeyEventType) {
    var k = KeyEvent()
    k.codeType = .mac
    k.eventType = type
    k.keyCode = Int32(e.keyCode)
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
  let emulator = Process()
  var window: NSWindow!
  var quitting = false

  func applicationDidFinishLaunching(_ note: Notification) {
    emulator.executableURL = URL(fileURLWithPath: sdk + "/emulator/emulator")
    emulator.arguments = ["-avd", avd, "-no-window", "-gpu", "host", "-grpc", "\(grpcPort)", "-grpc-use-token", "-no-boot-anim"]
    emulator.terminationHandler = { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
    do { try emulator.run() } catch { fatal("cannot launch emulator: \(error)") }

    let (inputs, inputsCont) = AsyncStream.makeStream(of: InputEvent.self)
    let view = ScreenView(inputs: inputsCont)
    let screenH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
    window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: screenH * 9 / 20, height: screenH),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = avd
    window.contentView = view
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)

    Task.detached { [weak view, weak self] in
      do {
        try await Self.run(inputs: inputs) { img in await MainActor.run { view?.show(img) } }
      } catch {
        // The stream always dies while we shut the emulator down; only alert on unexpected failures.
        await MainActor.run { if self?.quitting == false { fatal("gRPC: \(error)") } }
      }
    }
  }

  nonisolated static func run(inputs: AsyncStream<InputEvent>, onFrame: @escaping @Sendable (CGImage) async -> Void) async throws {
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
        group.addTask { [md, fmt] in
          try await ec.streamScreenshot(fmt, metadata: md) { response in
            for try await img in response.messages {
              if let cg = fb.image(width: Int(img.format.width), height: Int(img.format.height)) { await onFrame(cg) }
            }
          }
        }
        try await group.next()
        group.cancelAll()
      }
    }
  }

  func applicationWillTerminate(_ note: Notification) {
    quitting = true
    guard emulator.isRunning else { return }
    emulator.terminationHandler = nil
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

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
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
