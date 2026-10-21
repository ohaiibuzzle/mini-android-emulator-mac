import AppKit

/// Mini's own engine: upstream QEMU with patches/qemu, gfxstream and rutabaga built from source (scripts/build-qemu.sh).
/// It boots Google's goldfish system images, with each device's config and disks under Prefs.devices.
enum Qemu {
  /// Bundled into Mini.app by bundle.sh; a `swift run` build uses the repo's third_party/install.
  static var root: String {
    Bundle.main.resourcePath.map { $0 + "/qemu" }.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
      ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../third_party/install").standardized.path
  }
  static var binary: String { root + "/bin/qemu-system-aarch64" }
  static var qemuImg: String { root + "/bin/qemu-img" }
  static var installed: Bool { FileManager.default.isExecutableFile(atPath: binary) }
  static let mke2fs = "/opt/homebrew/opt/e2fsprogs/sbin/mke2fs"
  /// ANGLE's GLSL translator, which gfxstream's host GLES decoder dlopens. CI builds it; bundle.sh copies it if it's there.
  static var shaderTranslator: String { root + "/lib/libshadertranslator.dylib" }
  static var hostGLESAvailable: Bool { FileManager.default.fileExists(atPath: shaderTranslator) }

  /// QEMU's environment. Host GLES needs two things gfxstream only reads from it.
  static func environment(hostGLES: Bool) -> [String: String] {
    var env = ProcessInfo.processInfo.environment.merging(["ANDROID_EMU_VK_ICD": "moltenvk"]) { _, new in new }
    if hostGLES {
      env["ANDROID_EMU_RENDERER"] = "host"  // otherwise it sets GL up as for SwiftShader: a GL 2.1 context, GLES 2 at most
      env["DYLD_FALLBACK_LIBRARY_PATH"] = (shaderTranslator as NSString).deletingLastPathComponent  // dlopened by bare name
    }
    return env
  }

  /// 127.0.0.1:`port`, for QEMU's adb socket and the adb server.
  static func loopback(_ port: Int) -> sockaddr_in {
    sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: in_port_t(port).bigEndian,
                sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
  }

  /// Whether QEMU could listen on `port`. SO_REUSEADDR as QEMU sets it, so a just-stopped device's TIME_WAIT doesn't count.
  static func canListen(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var addr = loopback(port)
    return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
  }

  /// What the emulator's bootconfig says, with graphics moved from goldfish_pipe to virtio-gpu (gfxstream ASG) and
  /// minigbm gralloc (the ranchu mapper needs goldfish_address_space, which upstream QEMU lacks).
  static func bootconfig(avd: String, config: DeviceConfig, vbmeta: [String], adbKey: String?, logcat: Bool) -> [(String, String)] {
    var kv: [(String, String)] = [
      ("boot_devices", "a003600.virtio_mmio"),
      ("dalvik.vm.heapsize", "576m"),
      ("debug.hwui.renderer", "skiagl"),
      ("hardware", "ranchu"),
      ("hardware.gltransport", "virtio-gpu-asg"),
      ("hardware.gralloc", "minigbm"),
      ("hardware.vulkan", "ranchu"),
      // Vendor init copies it to ro.hardware.egl. "emulation" is goldfish's GLES driver, streaming to the host decoder.
      ("hardwareegl", config.hostGLES ? "emulation" : "angle"),
      ("opengles.version", "196609"),
      ("qemu", "1"),
      ("qemu.avd_name", avd),
      ("qemu.gltransport.drawFlushInterval", "800"),
      ("qemu.gltransport.name", "virtio-gpu-asg"),
      ("qemu.settings.system.screen_off_timeout", "2147483647"),
      ("qemu.skin", "\(config.size.width)x\(config.size.height)"),
      ("qemu.vsync", "\(config.refreshHz)"),
      ("serialno", "EMULATOR37X3X4X0"),
      ("veritymode", "enforcing"),
    ]
    if let adbKey { kv.append(("qemu.adb.pubkey", adbKey)) }
    if logcat { kv.append(("logcat", "*:W")) }
    if config.freeform { kv.append(("qemu.display.settings.xml", "freeform")) }
    // VerifiedBootParams.textproto: `param: "androidboot.vbmeta.size=6784"`.
    for p in vbmeta {
      guard let eq = p.firstIndex(of: "="), p.hasPrefix("androidboot.") else { continue }
      kv.append((String(p[p.index(p.startIndex, offsetBy: 12)..<eq]), String(p[p.index(after: eq)...])))
    }
    return kv
  }

  /// Linux bootconfig appended to an initrd: `key="value"` lines, NUL-padded to 4 bytes, then size, checksum and magic.
  static func appendBootconfig(_ kv: [(String, String)], to ramdisk: Data) -> Data {
    var text = Data(kv.map { "androidboot.\($0.0)=\"\($0.1)\"\n" }.joined().utf8)
    text.append(contentsOf: [UInt8](repeating: 0, count: (4 - text.count % 4) % 4))
    let sum = text.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    var out = ramdisk + text
    withUnsafeBytes(of: UInt32(text.count).littleEndian) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: sum.littleEndian) { out.append(contentsOf: $0) }
    out.append(contentsOf: "#BOOTCONFIG\n".utf8)
    return out
  }

  /// The device's disks, made on first boot, as vda...vde: vendor, metadata key, userdata, cache, system.
  /// (virtio-mmio slots fill from the top, which puts system at a003600, what androidboot.boot_devices names.)
  /// Writable disks are a sparse raw base and a qcow2 overlay on it, which savevm needs.
  static func disks(dir: String, sysdir: String, storageMB: Int) throws -> [(path: String, readOnly: Bool)] {
    let fm = FileManager.default
    func overlay(_ name: String, create: (String) throws -> Void) throws -> String {
      let base = "\(dir)/\(name)", top = base + ".qcow2"
      if fm.fileExists(atPath: top) { return top }
      if !fm.fileExists(atPath: base) { try create(base) }
      try run(qemuImg, ["create", "-q", "-f", "qcow2", "-F", "raw", "-b", name, top])  // backing path relative to top
      return top
    }
    let key = try overlay("encryptionkey.img") { try fm.copyItem(atPath: sysdir + "encryptionkey.img", toPath: $0) }
    let data = try overlay("userdata-qemu.img") { path in
      // /data isn't formattable in fstab.ranchu, so it must start as ext4; the image's data/ seeds it like the emulator does.
      // The new file is sparse, so it is already zero: skip zeroing inode tables here and in the guest's ext4lazyinit,
      // which otherwise writes gigabytes and stalls the guest on a large disk.
      guard fm.isExecutableFile(atPath: mke2fs) else { throw SetupError("A new device on QEMU needs e2fsprogs: brew install e2fsprogs") }
      try run(mke2fs, ["-q", "-F", "-t", "ext4", "-L", "data", "-E", "lazy_itable_init=0,lazy_journal_init=0,assume_storage_prezeroed=1",
                       "-d", sysdir + "data", path, "\(storageMB)M"])
    }
    let cache = try overlay("cache.img") { path in
      // Not mounted (fstab.ranchu has no /cache); it only holds the slot.
      guard fm.createFile(atPath: path, contents: nil), let h = FileHandle(forWritingAtPath: path) else { throw SetupError("cannot create \(path)") }
      try h.truncate(atOffset: 66 << 20)
      try h.close()
    }
    return [(sysdir + "vendor.img", true), (key, false), (data, false), (cache, false), (sysdir + "system.img", true)]
  }

  static func run(_ exe: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw SetupError("\((exe as NSString).lastPathComponent) failed (\(p.terminationStatus))") }
  }

  /// Connects to one of QEMU's unix socket chardevs, which appear a moment after launch.
  static func connect(_ path: String) async throws -> FileHandle {
    while true {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      var addr = sockaddr_un()
      addr.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &addr.sun_path) { path.utf8CString.withUnsafeBytes($0.copyMemory(from:)) }
      let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
      if ok == 0 { return FileHandle(fileDescriptor: fd, closeOnDealloc: true) }
      close(fd)
      try await Task.sleep(for: .milliseconds(200))
    }
  }

  /// Writes the initrd and readies the disks; returns QEMU's command line.
  static func arguments(avd: String, adbPort: Int, socket: String, shm: String, log: String) throws -> [String] {
    let ini = Prefs.ini(try String(contentsOfFile: Prefs.configPath(avd: avd), encoding: .utf8))
    var config = DeviceConfig(ini)
    config.hostGLES = config.hostGLES && hostGLESAvailable
    let dir = (Prefs.configPath(avd: avd) as NSString).deletingLastPathComponent
    let sysdir = Prefs.home + "/" + config.sysdir
    let d = UserDefaults.standard

    let vbmeta = ((try? String(contentsOfFile: sysdir + "VerifiedBootParams.textproto", encoding: .utf8)) ?? "")
      .split(separator: "\n").compactMap { $0.hasPrefix("param: \"") ? String($0.dropFirst(8).dropLast()) : nil }
    let adbKey = (try? String(contentsOfFile: NSHomeDirectory() + "/.android/adbkey.pub", encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let initrd = dir + "/initrd-mini"
    let kv = bootconfig(avd: avd, config: config, vbmeta: vbmeta, adbKey: adbKey, logcat: d.bool(forKey: Prefs.debugLogs))
    try appendBootconfig(kv, to: Data(contentsOf: URL(fileURLWithPath: sysdir + "ramdisk.img")))
      .write(to: URL(fileURLWithPath: initrd))

    var args = [
      "-M", "virt", "-accel", "hvf", "-cpu", "host", "-smp", "\(config.cores)", "-m", "\(config.ramMB)",
      "-nodefaults", "-display", "none", "-kernel", sysdir + "kernel-ranchu", "-initrd", initrd,
      "-append", "console=ttyAMA0 earlycon keep_bootcon printk.devkmsg=on bootconfig loop.max_part=7 cgroup_disable=pressure "
        + "stack_depot_disable=on kasan.stacktrace=off mac80211_hwsim.radios=0 ndns=2",
      "-serial", d.bool(forKey: Prefs.debugLogs) ? "file:\(log)-kernel.log" : "null",
    ]
    for (i, disk) in try disks(dir: dir, sysdir: sysdir, storageMB: config.storageMB).enumerated() {
      // Writable disks are qcow2 overlays; trimmed or zeroed guest blocks give their clusters back.
      let opts = disk.readOnly ? "format=raw,read-only=on" : "format=qcow2,discard=unmap,detect-zeroes=unmap"
      args += ["-drive", "if=none,id=d\(i),file=\(disk.path),\(opts)",
               "-device", "virtio-blk-device,drive=d\(i)"]
    }
    args += [
      "-netdev", "user,id=net", "-device", "virtio-net-device,netdev=net", "-device", "virtio-rng-device",
      "-chardev", "null,id=hvc0", "-chardev", d.bool(forKey: Prefs.debugLogs) ? "file,id=hvc1,path=\(log)-logcat.log" : "null,id=hvc1",
      "-device", "virtio-serial-pci", "-device", "virtconsole,chardev=hvc0", "-device", "virtconsole,chardev=hvc1",
      // Port 2 of virtio-serial, which the guest numbers vport7 after the seven virtio-mmio devices above.
      "-chardev", "socket,id=modem,path=\(socket).modem,server=on,wait=off", "-device", "virtserialport,chardev=modem,name=modem",
      // Port 3: the other end of the guest's bt_vhci_forwarder, answered by Bluetooth.run.
      "-chardev", "socket,id=bluetooth,path=\(socket).bluetooth,server=on,wait=off",
      "-device", "virtserialport,chardev=bluetooth,name=bluetooth",
      "-device", "virtio-keyboard-pci", "-device", "virtio-multitouch-pci", "-device", "virtio-mouse-pci",
      "-device", "virtio-gamepad-pci",  // Gamepad's; an Xbox 360 pad to Android
      // One output and one input stream; the ranchu audio HAL drives them through virtio_snd.
      "-audiodev", "coreaudio,id=snd", "-device", "virtio-sound-pci,audiodev=snd",
      // GuestVulkanOnly: guest ANGLE draws everything through Vulkan, so the host needs no GLES. Without it, guest GLES goes
      // to gfxstream's translator on Apple's OpenGL 4.1 (GLES 3.0); Vulkan takes the same path either way.
      "-device", "virtio-gpu-rutabaga-pci,gfxstream-vulkan=on,x-gfxstream-gles=on,x-gfxstream-composer=on,hostmem=1G,"
        + (config.hostGLES ? "" : "x-gfxstream-features=GuestVulkanOnly:enabled,")
        + "xres=\(config.size.width),yres=\(config.size.height)",
      "-chardev", "socket,id=adb,host=127.0.0.1,port=\(adbPort),server=on,wait=off",
      // sensors=1: the accelerometer, which mini-display tilts when Mini rotates.
      "-device", "android-vsock-pci,guest-cid=3,adb=adb,sensors=1,boot-props=qemu.sf.lcd_density=\(config.size.density);qemu.hw.mainkeys=0;"
        + "vendor.qemu.vport.modem=/dev/vport7p2;vendor.qemu.vport.bluetooth=/dev/vport7p3",
      "-chardev", "socket,id=mini,path=\(socket),server=on,wait=off",
      "-object", "mini-display,id=display,chardev=mini,shm=\(shm)",
    ]
    return args
  }
}

/// mini-display's wire format (third_party/qemu/ui/mini.c).
enum MiniMsg {
  static let touch: UInt8 = 1, key: UInt8 = 2, macKey: UInt8 = 3, rotate: UInt8 = 4, pointer: UInt8 = 5, pad: UInt8 = 6

  /// `arg` is a touch's finger (0...9), a pointer's wheel notches (+ is up) or a pad event's evdev type.
  static func encode(_ type: UInt8, _ a: Int32, _ b: Int32 = 0, _ c: Int32 = 0, arg: Int8 = 0) -> Data {
    var d = Data([type, UInt8(bitPattern: arg), 0, 0])
    for v in [a, b, c] { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    return d
  }

  /// W3C key names Mini's buttons send → Linux key codes the virtio keyboard has. The guest reads them through
  /// goldfish's /vendor/usr/keylayout/qwerty2.kl, where HOME is KEY_HOME (102); it has no KEY_HOMEPAGE (172).
  static let named: [String: Int32] = ["GoBack": 158, "GoHome": 102, "Power": 116, "AudioVolumeUp": 115, "AudioVolumeDown": 114]
}

/// Runs adb against one guest: registers it with the adb server, then sets up what the boot can't.
struct GuestSetup: Sendable {
  /// QEMU's adb port. adb names the guest emulator-<adbPort - 1>, after the console port the emulator would have.
  let adbPort: Int
  var serial: String { "emulator-\(adbPort - 1)" }


  static var adb: String { PlatformTools.dir + "/adb" }

  @discardableResult
  static func adb(_ args: [String]) async -> Bool {
    await withCheckedContinuation { cont in
      let p = Process()
      p.executableURL = URL(fileURLWithPath: adb)
      p.arguments = args
      p.standardOutput = FileHandle.nullDevice
      p.standardError = FileHandle.nullDevice
      p.terminationHandler = { cont.resume(returning: $0.terminationStatus == 0) }
      do { try p.run() } catch { cont.resume(returning: false) }
    }
  }

  /// Whether Mini started the adb server, which it then stops on quit: macOS 27 shows Mini as "Running in Background"
  /// for as long as a process it launched lives on. A server someone else started is theirs.
  @MainActor static var startedServer = false

  /// Starts the adb server unless one runs, noting which. Any other adb command would start it without telling.
  static func startServer() async {
    if Qemu.canListen(5037) { await MainActor.run { startedServer = true } }
    await adb(["start-server"])
  }

  /// `host:emulator:<port>` is how the emulator tells a running adb server about itself; it then shows as emulator-<port-1>.
  func register() async {
    await Self.startServer()
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var addr = Qemu.loopback(5037)
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard ok == 0 else { return }
    let req = "host:emulator:\(adbPort)"
    _ = (String(format: "%04x", req.utf8.count) + req).withCString { write(fd, $0, strlen($0)) }
  }

  /// Registers until adb sees the guest: QEMU's adb socket opens a moment after launch, and an adbd restart drops it.
  func reach() async {
    await Self.startServer()
    while !Task.isCancelled, !(await Self.adb(["-s", serial, "get-state"])) {
      await register()
      try? await Task.sleep(for: .seconds(2))
    }
  }

  /// Whether the guest finished booting; false if it went away first.
  func waitForBoot() async -> Bool {
    await reach()
    return await Self.adb(["-s", serial, "shell", "until [ \"$(getprop sys.boot_completed)\" = 1 ]; do sleep 1; done"])
  }

  /// Gives the booted guest internet: the image only routes through Wi-Fi, so virt_wifi dresses eth0
  /// (QEMU's user network) up as the "VirtWifi" access point. That needs root, and `adb root` restarts adbd, which
  /// drops the transport, so the guest is registered again. Then lifts Android's 60 Hz default refresh cap.
  func afterBoot(refreshHz: Int) async {
    // Images with an Ethernet service (PixelOS) use eth0 as is; the stock image has only Wi-Fi, so eth0 gets wrapped in virt_wifi.
    if !(await Self.adb(["-s", serial, "shell", "service check ethernet | grep -q ': found'"])) {
      // shortcut: images whose adbd refuses root (user builds) stay offline; upgrade to a host-side Wi-Fi AP.
      await Self.adb(["-s", serial, "root"])
      try? await Task.sleep(for: .seconds(2))
      await reach()
      await Self.adb(["-s", serial, "shell", "ip link set eth0 up; ip link show wlan0 >/dev/null 2>&1 || ip link add link eth0 name wlan0 type virt_wifi; "
        + "cmd wifi set-wifi-enabled enabled; sleep 3; cmd wifi connect-network VirtWifi open"])
    }
    if refreshHz > 60 { await Self.adb(["-s", serial, "shell", "settings put system min_refresh_rate \(refreshHz)"]) }
  }

  /// A clean shutdown, so /data is unmounted before QEMU exits.
  func powerOff() async -> Bool { await Self.adb(["-s", serial, "shell", "svc power shutdown"]) }
}
