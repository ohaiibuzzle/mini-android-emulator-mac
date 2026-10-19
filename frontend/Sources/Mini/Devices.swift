import AppKit
import SwiftUI

/// An installed system-image dir under Mini's folder, named the way config.ini's image.sysdir.1 names it.
struct SystemImage: Hashable, Identifiable {
  let sysdir: String  // "system-images/android-37.0/google_apis/arm64-v8a/"
  let props: [String: String]  // source.properties
  var id: String { sysdir }
  var target: String { sysdir.split(separator: "/")[1].description }  // "android-37.0"
  var tagID: String { props["SystemImage.TagId"]?.split(separator: ",").first.map(String.init) ?? "default" }
  var tagDisplay: String { props["SystemImage.TagDisplay"]?.split(separator: ",").first.map(String.init) ?? tagID }
  var abi: String { props["SystemImage.Abi"] ?? "arm64-v8a" }
  var label: String { "\(tagDisplay) · \(target)" }

  /// Every `system-images/<api>/<tag>/<abi>/` that has a system.img.
  static func installed() -> [SystemImage] {
    let fm = FileManager.default, root = Prefs.home + "/"
    let ls = { (p: String) in ((try? fm.contentsOfDirectory(atPath: root + p)) ?? []).filter { !$0.hasPrefix(".") }.sorted() }
    var dirs: [String] = []
    for api in ls("system-images") {
      for tag in ls("system-images/\(api)") { dirs += ls("system-images/\(api)/\(tag)").map { "system-images/\(api)/\(tag)/\($0)/" } }
    }
    return dirs.filter { fm.fileExists(atPath: root + $0 + "system.img") }.map { dir in
      let props = (try? String(contentsOfFile: root + dir + "source.properties", encoding: .utf8)) ?? ""
      return SystemImage(sysdir: dir, props: Prefs.ini(props))
    }
  }
}

/// The part of a device's config.ini that Mini edits, in the emulator's keys.
struct DeviceConfig: Equatable {
  var size = DisplaySize()
  var ramMB = 2048
  var storageMB = 6144  // userdata; a new size only applies to a freshly made data disk
  var freeform = false
  var refreshHz = 60
  var sysdir = BaseImage.sysdir  // read-only after creation

  static let refreshChoices = [60, 90, 120]

  init() {}

  init(_ ini: [String: String]) {
    let lcd = ["hw.lcd.width", "hw.lcd.height", "hw.lcd.density"].map { ini[$0].flatMap(Int.init) }
    if let w = lcd[0], let h = lcd[1], let d = lcd[2] { size = DisplaySize(width: w, height: h, density: d) }
    ramMB = ini["hw.ramSize"].flatMap { Self.megabytes($0) } ?? ramMB
    storageMB = ini["disk.dataPartition.size"].flatMap { Self.megabytes($0, bare: 1) } ?? storageMB
    freeform = ini["display.settings.xml"] == "freeform"
    refreshHz = ini["hw.lcd.vsync"].flatMap(Int.init) ?? refreshHz
    sysdir = ini["image.sysdir.1"] ?? sysdir
  }

  /// Sizes with an optional M or G suffix. A bare number is MB for hw.ramSize but bytes for
  /// disk.dataPartition.size (what Android Studio writes), so `bare` is its unit in bytes.
  static func megabytes(_ s: String, bare: Int = 1 << 20) -> Int? {
    let v = s.trimmingCharacters(in: .whitespaces).uppercased()
    if v.hasSuffix("G") { return Int(v.dropLast()).map { $0 * 1024 } }
    if v.hasSuffix("M") { return Int(v.dropLast()) }
    return Int(v).map { $0 * bare / (1 << 20) }
  }

  /// Within what the guest boots with.
  var valid: Bool { size.valid && (1024...65536).contains(ramMB) && (2048...1 << 20).contains(storageMB) }

  var values: [String: String?] {
    [
      "hw.lcd.width": "\(size.width)", "hw.lcd.height": "\(size.height)", "hw.lcd.density": "\(size.density)",
      "hw.ramSize": "\(ramMB)M", "disk.dataPartition.size": "\(storageMB)M",
      // Becomes androidboot.qemu.display.settings.xml; Google's provisioning app enables desktop windows.
      "display.settings.xml": freeform ? "freeform" : nil,
      "hw.lcd.vsync": "\(refreshHz)",  // the guest display's only mode; Mini lifts Android's 60 Hz default cap after boot
    ]
  }

  static func load(avd: String) -> DeviceConfig? {
    (try? String(contentsOfFile: Prefs.configPath(avd: avd), encoding: .utf8)).map { DeviceConfig(Prefs.ini($0)) }
  }

  func save(avd: String) throws {
    let path = Prefs.configPath(avd: avd)
    let text = try String(contentsOfFile: path, encoding: .utf8)
    try Prefs.ini(text, setting: values).write(toFile: path, atomically: true, encoding: .utf8)
  }
}

@MainActor
enum Devices {
  /// The device this Mini process is running, if any.
  static var running: String?

  static func validName(_ name: String) -> Bool {
    !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
  }

  /// Writes `Devices/<name>/config.ini`; Qemu.disks makes the disks on first boot.
  static func create(name: String, image: SystemImage, config: DeviceConfig) throws {
    let fm = FileManager.default, dir = "\(Prefs.devices)/\(name)"
    guard validName(name), !fm.fileExists(atPath: dir) else { throw SetupError("\(name) exists or isn't a valid device name") }
    try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var c = config
    c.sysdir = image.sysdir
    let base: [String: String?] = ["hw.cpu.ncore": "4", "image.sysdir.1": image.sysdir]
    try Prefs.ini("", setting: base.merging(c.values) { _, new in new })
      .write(toFile: "\(dir)/config.ini", atomically: true, encoding: .utf8)
  }

  /// Moves the device's directory to the Trash (recoverable). Its system image stays.
  static func delete(_ name: String) throws {
    try FileManager.default.trashItem(at: URL(fileURLWithPath: "\(Prefs.devices)/\(name)"), resultingItemURL: nil)
  }

  /// What a data wipe removes; Qemu.disks makes a fresh data disk at the configured size.
  static func dataFiles(_ name: String) -> [String] {
    let dir = URL(fileURLWithPath: Prefs.configPath(avd: name)).deletingLastPathComponent().path
    return ["userdata-qemu.img", "userdata-qemu.img.qcow2"].map { "\(dir)/\($0)" }
  }

  static func erase(_ name: String) throws {
    for path in dataFiles(name) where FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
  }

  /// Quits (the guest shuts down) and reopens Mini on `name`, erasing its data in between if asked.
  static func relaunch(with name: String, erase: Bool = false) {
    UserDefaults.standard.set(name, forKey: Prefs.avd)
    // shortcut: a `swift run` build isn't an app bundle, so it just quits; relaunch it by hand.
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; a=$2 n=$3; shift 3; rm -rf \"$@\"; exec /usr/bin/open \"$a\" --args --start \"$n\"",
                    "sh", "\(getpid())", Bundle.main.bundlePath, name] + (erase ? dataFiles(name) : [])
    if Bundle.main.bundlePath.hasSuffix(".app") { try? sh.run() }
    NSApp.terminate(nil)
  }
}

/// Converts a GSI with scripts/gsi-image.py (bundled into Mini.app) on top of Google's base image.
enum GSIImport {
  static let brew = "/opt/homebrew"
  static let tools = ["\(brew)/bin/lz4"] + ["resize2fs", "e2fsck", "debugfs"].map { "\(brew)/opt/e2fsprogs/sbin/\($0)" }
  static var missingTools: Bool { !tools.allSatisfy(FileManager.default.isExecutableFile(atPath:)) }
  static let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Mini/gsi-import.log")

  static var script: String {
    // A `swift run` build has no bundle; use the repo's copy next to frontend/.
    Bundle.main.path(forResource: "gsi-image", ofType: "py")
      ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../scripts/gsi-image.py").path
  }

  /// `system-images/android-37.0/gsi_<name>/arm64-v8a/`: the base's API, since its kernel and vendor are what boots.
  static func sysdir(for name: String) -> String {
    let tag = "gsi_" + String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
    return BaseImage.sysdir.replacingOccurrences(of: "/google_apis/", with: "/\(tag)/")
  }

  static func run(gsi: URL, name: String) async throws -> SystemImage {
    let out = Prefs.home + "/" + sysdir(for: name)
    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-I", script, BaseImage.dir, gsi.path, out, name]
    p.environment = ["PATH": "\(brew)/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
    let h = try FileHandle(forWritingTo: log)
    p.standardOutput = h
    p.standardError = h
    let status: Int32 = try await withCheckedThrowingContinuation { cont in
      p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
      do { try p.run() } catch { p.terminationHandler = nil; cont.resume(throwing: error) }
    }
    try? h.close()
    guard status == 0 else {
      let tail = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").suffix(3).joined(separator: "\n")
      throw SetupError("gsi-image.py exited \(status):\n\(tail)\nFull log: \(log.path)")
    }
    guard let image = SystemImage.installed().first(where: { $0.sysdir == sysdir(for: name) }) else {
      throw SetupError("conversion finished but \(out) has no system.img")
    }
    return image
  }
}

struct DevicesView: View {
  @State private var names = Prefs.avds()
  @State private var selection: String?
  @State private var config = DeviceConfig()
  @State private var saved: DeviceConfig?
  @State private var error: String?
  @State private var creating: NewDeviceView.Source?
  @State private var confirmDelete = false
  @State private var eraseThenStart: Bool?  // set while asking to erase data for a storage change

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        List(names, id: \.self, selection: $selection) { name in
          HStack {
            Text(name)
            Spacer()
            if name == Devices.running { Text("Running").font(.caption).foregroundStyle(.secondary) }
          }
        }
        Divider()
        HStack {
          Button { creating = .image } label: { Image(systemName: "plus") }.help("New device")
          Button { confirmDelete = true } label: { Image(systemName: "minus") }
            .help("Move device to Trash").disabled(selection == nil || selection == Devices.running)
          Spacer()
          Button("Import GSI…") { creating = .gsi }
        }
        .buttonStyle(.borderless).padding(8)
      }
      .frame(width: 220)
      Divider()
      if let name = selection, saved != nil { detail(name) } else {
        Text(names.isEmpty ? "No devices yet. Create one with + or Import GSI…" : "Select a device")
          .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(width: 760, height: 520)
    .onAppear {
      let last = UserDefaults.standard.string(forKey: Prefs.avd).flatMap { names.contains($0) ? $0 : nil }
      selection = selection ?? Devices.running ?? last ?? names.first
      load()
    }
    .onChange(of: selection) { load() }
    .sheet(item: $creating) { source in
      NewDeviceView(source: source) { created in
        creating = nil
        if let created { names = Prefs.avds(); selection = created }
      }
    }
    .confirmationDialog("Move \(selection ?? "") to the Trash?", isPresented: $confirmDelete) {
      Button("Move to Trash", role: .destructive) {
        guard let name = selection else { return }
        do { try Devices.delete(name); names = Prefs.avds(); selection = names.first } catch { self.error = error.localizedDescription }
      }
    } message: { Text("Its system image stays installed.") }
  }

  private func detail(_ name: String) -> some View {
    Form {
      Section {
        LabeledContent("Image", value: SystemImage.installed().first { $0.sysdir == config.sysdir }?.label ?? config.sysdir)
      } header: { Text(name).font(.title2) }
      Section("Screen") {
        Picker("Preset", selection: $config.size) {
          ForEach(DisplaySize.presets, id: \.0) { Text($0.0).tag($0.1) }
          if !DisplaySize.presets.contains(where: { $0.1 == config.size }) { Text("Custom").tag(config.size) }
        }
        TextField("Width (px)", value: $config.size.width, format: .number.grouping(.never))
        TextField("Height (px)", value: $config.size.height, format: .number.grouping(.never))
        TextField("Density (dpi)", value: $config.size.density, format: .number.grouping(.never))
        Text("\(config.size.width * 160 / max(config.size.density, 1)) dp wide").font(.caption).foregroundStyle(.secondary)
      }
      Section("Hardware") {
        TextField("Memory (MB)", value: $config.ramMB, format: .number.grouping(.never))
        TextField("Storage (MB)", value: $config.storageMB, format: .number.grouping(.never))
        Text("Memory 1024–65536 MB, storage at least 2048 MB. Changing storage erases the device's data.")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("Desktop windowing (freeform)", isOn: $config.freeform)
        Picker("Refresh rate", selection: $config.refreshHz) {
          ForEach(DeviceConfig.refreshChoices, id: \.self) { Text("\($0) Hz").tag($0) }
          if !DeviceConfig.refreshChoices.contains(config.refreshHz) { Text("\(config.refreshHz) Hz").tag(config.refreshHz) }
        }
      }
      Section {
        HStack {
          Text(error ?? "Changes apply the next time the device boots.")
            .font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.red)
          Spacer()
          Button("Save") { if erasing { eraseThenStart = false } else { commit(name, start: false) } }
            .disabled(!config.valid || config == saved)
          Button(name == Devices.running ? "Restart" : "Start") { if erasing { eraseThenStart = true } else { commit(name, start: true) } }
            .keyboardShortcut(.defaultAction).disabled(!config.valid)
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog("Erase \(name)'s data?", isPresented: Binding { eraseThenStart != nil } set: { if !$0 { eraseThenStart = nil } }) {
      Button("Erase and Save", role: .destructive) { commit(name, start: eraseThenStart ?? false) }
    } message: {
      Text("The new storage size needs a fresh data partition: apps, files and settings on this device are lost."
        + (name == Devices.running ? " It restarts now." : ""))
    }
  }

  private var erasing: Bool { saved.map { $0.storageMB != config.storageMB } ?? false }

  /// Saves, erases data if storage changed (after quitting, for the running device), and starts if asked.
  private func commit(_ name: String, start: Bool) {
    let erase = erasing
    do {
      try config.save(avd: name)
      saved = config
      error = nil
      if start || (erase && name == Devices.running) { Devices.relaunch(with: name, erase: erase) } else if erase { try Devices.erase(name) }
    } catch { self.error = error.localizedDescription }
  }

  private func load() {
    saved = selection.flatMap(DeviceConfig.load(avd:))
    config = saved ?? DeviceConfig()
    error = nil
  }
}

/// New device from an installed image, or from a GSI file converted onto the base image.
struct NewDeviceView: View {
  enum Source: String, Identifiable { case image, gsi; var id: String { rawValue } }
  @State var source: Source
  let done: (String?) -> Void
  @State private var name = ""
  @State private var images = SystemImage.installed()
  @State private var image: SystemImage?
  @State private var gsi: URL?
  @State private var config = DeviceConfig()
  @State private var busy = false
  @State private var error: String?
  @State private var baseInstalled = BaseImage.installed

  var body: some View {
    Form {
      Picker("Source", selection: $source) {
        Text("Installed image").tag(Source.image)
        Text("GSI file").tag(Source.gsi)
      }
      .pickerStyle(.segmented)
      TextField("Name", text: $name)
      if !name.isEmpty && !nameOK {
        Text("Use letters, digits, . _ - and a name no other device has.").font(.caption).foregroundStyle(.red)
      }
      if source == .image {
        Picker("Image", selection: $image) {
          ForEach(images) { Text($0.label).tag(Optional($0)) }
        }
      } else {
        LabeledContent("GSI") {
          Button(gsi?.lastPathComponent ?? "Choose…", action: chooseGSI)
        }
        if GSIImport.missingTools {
          Text("Import needs lz4 and e2fsprogs: brew install lz4 e2fsprogs").font(.caption).foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      if !baseInstalled {
        HStack {
          Text(source == .gsi ? "Import GSI needs Google's API 37 base image." : "Google's API 37 image isn't installed.")
            .font(.caption)
          Spacer()
          Button("Download…") { SetupWindow.showBaseImage { refresh() } }
        }
      }
      Picker("Screen", selection: $config.size) {
        ForEach(DisplaySize.presets, id: \.0) { Text($0.0).tag($0.1) }
      }
      .onChange(of: config.size) { config.freeform = config.size == DisplaySize.presets[2].1 }
      Toggle("Desktop windowing (freeform)", isOn: $config.freeform)
      TextField("Memory (MB)", value: $config.ramMB, format: .number.grouping(.never))
      TextField("Storage (MB)", value: $config.storageMB, format: .number.grouping(.never))
      if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        if busy { ProgressView().controlSize(.small); Text(source == .gsi ? "Converting…" : "").font(.caption) }
        Spacer()
        Button("Cancel") { done(nil) }.disabled(busy)
        Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(!ready || busy)
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .onAppear(perform: refresh)
  }

  private var nameOK: Bool { Devices.validName(name) && !Prefs.avds().contains(name) }
  private var ready: Bool {
    nameOK && config.valid && (source == .image ? image != nil : gsi != nil && baseInstalled && !GSIImport.missingTools)
  }

  private func refresh() {
    images = SystemImage.installed()
    baseInstalled = BaseImage.installed
    image = image ?? images.first { $0.sysdir == BaseImage.sysdir } ?? images.first
  }

  private func chooseGSI() {
    let panel = NSOpenPanel()
    panel.message = "Choose a GSI system image (.img or .img.xz, arm64)"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    gsi = url
    if name.isEmpty {
      // "LineageOS-24.0-UNOFFICIAL-…-arm64_ab-vanilla.img" → "LineageOS-24.0"
      let stem = url.lastPathComponent.split(separator: ".img").first.map(String.init) ?? "gsi"
      name = String(stem.split(separator: "-").prefix(2).joined(separator: "-").filter { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
    }
    if !config.freeform { config.size = DisplaySize.presets[2].1 }  // GSIs here are mostly for desktop testing
  }

  private func create() {
    busy = true
    error = nil
    Task {
      do {
        let img: SystemImage
        if source == .gsi, let gsi { img = try await GSIImport.run(gsi: gsi, name: name) } else { img = image! }
        try Devices.create(name: name, image: img, config: config)
        done(name)
      } catch {
        busy = false
        self.error = error.localizedDescription
      }
    }
  }
}

@MainActor
enum DevicesWindow {
  private static var window: NSWindow?

  static func show() {
    if window == nil {
      let w = NSWindow(contentViewController: NSHostingController(rootView: DevicesView()))
      w.title = "Devices"
      w.styleMask = [.titled, .closable]
      w.isReleasedWhenClosed = false
      window = w
    }
    window?.center()
    window?.makeKeyAndOrderFront(nil)
  }
}
