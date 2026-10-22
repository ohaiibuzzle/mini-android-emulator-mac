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
  var path: String { Prefs.home + "/" + sysdir }

  /// Devices that boot from this image; it can't go while any do.
  var users: [String] { Prefs.avds().filter { DeviceConfig.load(avd: $0)?.sysdir == sysdir } }

  /// Allocated bytes, as du counts them: a GSI's APFS clones of the base's files count in full.
  var size: String {
    let files = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
    let bytes = (files?.allObjects ?? []).compactMap { try? ($0 as? URL)?.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes.reduce(0, +)), countStyle: .file)
  }

  var trashWarning: String {
    sysdir == BaseImage.sysdir
      ? "New devices and GSI imports need Google's base image, so Mini will offer to download it again (about 2.2 GB)."
      : "Its space comes back once the Trash is emptied."
  }

  /// Moves the image to the Trash: its tag dir when this ABI is all it holds, so the Trash shows a recognizable name.
  func trash() throws {
    let fm = FileManager.default, dir = URL(fileURLWithPath: path), tag = dir.deletingLastPathComponent()
    let siblings = ((try? fm.contentsOfDirectory(atPath: tag.path)) ?? []).filter { !$0.hasPrefix(".") }
    try fm.trashItem(at: siblings == [dir.lastPathComponent] ? tag : dir, resultingItemURL: nil)
  }

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
  var cores = 4
  var ramMB = 2048
  var storageMB = 6144  // userdata; a new size only applies to a freshly made data disk
  var freeform = false
  var refreshHz = 60
  var hostGLES = false  // GLES on gfxstream's host translator instead of guest ANGLE
  var sysdir = BaseImage.sysdir  // read-only after creation

  static let refreshChoices = [60, 90, 120]

  init() {}

  init(_ ini: [String: String]) {
    let lcd = ["hw.lcd.width", "hw.lcd.height", "hw.lcd.density"].map { ini[$0].flatMap(Int.init) }
    if let w = lcd[0], let h = lcd[1], let d = lcd[2] { size = DisplaySize(width: w, height: h, density: d) }
    cores = ini["hw.cpu.ncore"].flatMap(Int.init) ?? cores
    ramMB = ini["hw.ramSize"].flatMap { Self.megabytes($0) } ?? ramMB
    storageMB = ini["disk.dataPartition.size"].flatMap { Self.megabytes($0, bare: 1) } ?? storageMB
    freeform = ini["display.settings.xml"] == "freeform"
    refreshHz = ini["hw.lcd.vsync"].flatMap(Int.init) ?? refreshHz
    hostGLES = ini["mini.gles"] == "host"
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
  var valid: Bool {
    size.valid && (1...Self.maxCores).contains(cores) && (1024...65536).contains(ramMB) && (2048...1 << 20).contains(storageMB)
  }
  static let maxCores = ProcessInfo.processInfo.activeProcessorCount  // HVF runs one host thread per vCPU

  var values: [String: String?] {
    [
      "hw.lcd.width": "\(size.width)", "hw.lcd.height": "\(size.height)", "hw.lcd.density": "\(size.density)",
      "hw.cpu.ncore": "\(cores)", "hw.ramSize": "\(ramMB)M", "disk.dataPartition.size": "\(storageMB)M",
      // Becomes androidboot.qemu.display.settings.xml; Google's provisioning app enables desktop windows.
      "display.settings.xml": freeform ? "freeform" : nil,
      "hw.lcd.vsync": "\(refreshHz)",  // the guest display's only mode; Mini lifts Android's 60 Hz default cap after boot
      "mini.gles": hostGLES ? "host" : nil,  // Mini's own key: the emulator has no such choice
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
    let base: [String: String?] = ["image.sysdir.1": image.sysdir]
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

  static func run(gsi: URL, name: String, secure: Bool) async throws -> SystemImage {
    let out = Prefs.home + "/" + sysdir(for: name)
    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-I", script] + (secure ? ["--secure"] : []) + [BaseImage.dir, gsi.path, out, name]
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
  @State private var soleImage: SystemImage?  // the selected device's image, when no other device uses it
  @State private var showImages = false
  @State private var eraseThenStart: Bool?  // set while asking to erase data for a storage change
  @State private var startHeadless = false  // which Start button asked
  private var fleet: Fleet { Fleet.shared }

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        List(names, id: \.self, selection: $selection) { name in
          HStack {
            Text(name)
            Spacer()
            if let m = fleet.machines[name] {
              Text(m.state.rawValue + (m.window == nil ? ", headless" : "")).font(.caption).foregroundStyle(.secondary)
            } else if fleet.failures[name] != nil {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).help(fleet.failures[name]!)
            }
          }
        }
        Divider()
        HStack {
          Button { creating = .image } label: { Image(systemName: "plus") }.help("New device")
          Button {
            soleImage = SystemImage.installed().first { $0.sysdir == config.sysdir && $0.users == [selection] }
            confirmDelete = true
          } label: { Image(systemName: "minus") }
            .help("Move device to Trash").disabled(selection == nil || fleet.machines[selection!] != nil)
          Spacer()
          Button("Images…") { showImages = true }
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
    .frame(minWidth: 760, minHeight: 520)
    .onAppear {
      let last = UserDefaults.standard.string(forKey: Prefs.avd).flatMap { names.contains($0) ? $0 : nil }
      selection = selection ?? fleet.machines.keys.sorted().first ?? last ?? names.first
      load()
    }
    .onChange(of: selection) { load() }
    .sheet(item: $creating) { source in
      NewDeviceView(source: source) { created in
        creating = nil
        if let created { names = Prefs.avds(); selection = created }
      }
    }
    .sheet(isPresented: $showImages) { ImagesView { showImages = false } }
    .confirmationDialog("Move \(selection ?? "") to the Trash?", isPresented: $confirmDelete) {
      Button("Move to Trash", role: .destructive) { deleteSelected(image: nil) }
      if let soleImage { Button("Move Device and Image to Trash", role: .destructive) { deleteSelected(image: soleImage) } }
    } message: {
      Text(soleImage.map { "No other device uses its image, \($0.label) (\($0.size)). \($0.trashWarning)" } ?? "Its system image stays installed.")
    }
  }

  private func deleteSelected(image: SystemImage?) {
    guard let name = selection else { return }
    do {
      try image?.trash()  // first: a failure then leaves the device selected, where its error shows
      try Devices.delete(name)
      names = Prefs.avds()
      selection = names.first
    } catch { self.error = error.localizedDescription }
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
        Stepper("CPU cores: \(config.cores)", value: $config.cores, in: 1...DeviceConfig.maxCores)
        TextField("Memory (MB)", value: $config.ramMB, format: .number.grouping(.never))
        TextField("Storage (MB)", value: $config.storageMB, format: .number.grouping(.never))
        Text("Memory 1024–65536 MB, storage at least 2048 MB. Changing storage erases the device's data.")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("Desktop windowing (freeform)", isOn: $config.freeform)
        Picker("Refresh rate", selection: $config.refreshHz) {
          ForEach(DeviceConfig.refreshChoices, id: \.self) { Text("\($0) Hz").tag($0) }
          if !DeviceConfig.refreshChoices.contains(config.refreshHz) { Text("\(config.refreshHz) Hz").tag(config.refreshHz) }
        }
        GLESPicker(hostGLES: $config.hostGLES)
      }
      Section {
        HStack {
          let message = error ?? fleet.failures[name]
          Text(message ?? "Changes apply the next time the device boots.")
            .font(.caption).foregroundStyle(message == nil ? Color.secondary : Color.red)
          Spacer()
          Button("Save") { if erasing { eraseThenStart = false } else { commit(name, start: false) } }
            .disabled(!config.valid || config == saved)
          if let m = fleet.machines[name] {
            if m.window == nil { Button("Show Window") { m.showWindow() } }
            Button("Stop") { Task { await m.stop() } }.disabled(m.state == .stopping)
            Button("Restart") { if erasing { eraseThenStart = true } else { commit(name, start: true) } }
              .keyboardShortcut(.defaultAction).disabled(!config.valid || m.state == .stopping)
          } else {
            Button("Start Headless") {
              if erasing { eraseThenStart = true; startHeadless = true } else { commit(name, start: true, headless: true) }
            }.help("Boots with no window; view and control it over adb, e.g. with scrcpy.").disabled(!config.valid)
            Button("Start") { if erasing { eraseThenStart = true } else { commit(name, start: true) } }
              .keyboardShortcut(.defaultAction).disabled(!config.valid)
          }
        }
      }
    }
    .formStyle(.grouped)
    .confirmationDialog("Erase \(name)'s data?", isPresented: Binding { eraseThenStart != nil } set: { if !$0 { eraseThenStart = nil; startHeadless = false } }) {
      Button("Erase and Save", role: .destructive) { commit(name, start: eraseThenStart ?? false, headless: startHeadless) }
    } message: {
      Text("The new storage size needs a fresh data partition: apps, files and settings on this device are lost."
        + (fleet.machines[name] != nil ? " It restarts now." : ""))
    }
  }

  private var erasing: Bool { saved.map { $0.storageMB != config.storageMB } ?? false }

  /// Saves, erases data if storage changed, and starts if asked. A running device stops first, and a restart keeps
  /// whether it had a window.
  private func commit(_ name: String, start: Bool, headless: Bool = false) {
    let erase = erasing
    do {
      try config.save(avd: name)
      saved = config
      error = nil
    } catch { return self.error = error.localizedDescription }
    let running = fleet.machines[name]
    let headless = running.map { $0.window == nil } ?? headless  // before stopping closes the window
    guard start || erase else { return }
    Task {
      await running?.stop()
      do {
        if erase { try Devices.erase(name) }
        if start || running != nil { try Machine.start(name, headless: headless) }
      } catch { self.error = error.localizedDescription }
    }
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
  @State private var secure = true
  @State private var config = DeviceConfig()
  @State private var busy = false
  @State private var error: String?
  @State private var baseInstalled = BaseImage.installed

  var body: some View {
    ZStack {
      form.disabled(!baseInstalled)
      if !baseInstalled { needsBase }
    }
    .frame(width: 480)
    .onAppear(perform: refresh)
  }

  /// Both sources boot on the base image (a GSI borrows its kernel and vendor), so nothing works until it's here.
  private var needsBase: some View {
    VStack(spacing: 14) {
      Image(systemName: "arrow.down.circle").font(.system(size: 40)).foregroundStyle(.secondary)
      Text("Mini needs to download Google's Android Studio base image to continue.")
        .font(.headline).multilineTextAlignment(.center)
      Text("New devices and imported GSIs both boot on Google's API 37 image (about 2.2 GB).")
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
      HStack {
        Button("Cancel") { done(nil) }
        Button("Download…") { SetupWindow.showBaseImage { refresh() } }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(30)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }

  private var form: some View {
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
        Text("Currently only supports Android 17 GSIs.").font(.caption).foregroundStyle(.secondary)
        // TrebleDroid's securize: hides its su and turns on adb authentication; root shell is gone for good.
        Toggle("Hide root (securize)", isOn: $secure)
        if GSIImport.missingTools {
          Text("Import needs lz4 and e2fsprogs: brew install lz4 e2fsprogs").font(.caption).foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      Picker("Screen", selection: $config.size) {
        ForEach(DisplaySize.presets, id: \.0) { Text($0.0).tag($0.1) }
      }
      .onChange(of: config.size) { config.freeform = config.size == DisplaySize.presets[2].1 }
      Toggle("Desktop windowing (freeform)", isOn: $config.freeform)
      GLESPicker(hostGLES: $config.hostGLES)
      Stepper("CPU cores: \(config.cores)", value: $config.cores, in: 1...DeviceConfig.maxCores)
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
        if source == .gsi, let gsi { img = try await GSIImport.run(gsi: gsi, name: name, secure: secure) } else { img = image! }
        try Devices.create(name: name, image: img, config: config)
        done(name)
      } catch {
        busy = false
        self.error = error.localizedDescription
      }
    }
  }
}

/// Installed images with their size and devices. One no device uses can go to the Trash.
struct ImagesView: View {
  let done: () -> Void
  @State private var rows: [(image: SystemImage, size: String, users: [String])] = []
  @State private var removing: SystemImage?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("System images").font(.headline)
      List(rows, id: \.image) { row in
        HStack {
          VStack(alignment: .leading) {
            Text(row.image.label)
            Text(row.users.isEmpty ? "Not used by any device" : "Used by " + row.users.joined(separator: ", "))
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Text(row.size).foregroundStyle(.secondary)
          Button { removing = row.image } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless).disabled(!row.users.isEmpty)
            .help(row.users.isEmpty ? "Move image to Trash" : "Delete \(row.users.joined(separator: ", ")) first")
        }
      }
      .frame(height: 260)
      if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Spacer()
        Button("Done", action: done).keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 480)
    .onAppear(perform: refresh)
    .confirmationDialog("Move \(removing?.label ?? "") to the Trash?", isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } }) {
      Button("Move to Trash", role: .destructive) {
        do { try removing?.trash(); error = nil } catch { self.error = error.localizedDescription }
        refresh()
      }
    } message: { Text(removing?.trashWarning ?? "") }
  }

  private func refresh() { rows = SystemImage.installed().map { ($0, $0.size, $0.users) } }
}

@MainActor
enum DevicesWindow {
  private static var window: NSWindow?

  static func show() {
    if window == nil {
      let w = NSWindow(contentViewController: NSHostingController(rootView: DevicesView()))
      w.title = "Devices"
      w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      w.isReleasedWhenClosed = false
      window = w
    }
    window?.center()
    window?.makeKeyAndOrderFront(nil)
  }
}

/// Who runs an app's OpenGL ES. Vulkan always goes through gfxstream to MoltenVK.
struct GLESPicker: View {
  @Binding var hostGLES: Bool

  var body: some View {
    Picker("OpenGL ES", selection: $hostGLES) {
      Text("ANGLE on Vulkan (ES 3.1)").tag(false)
      Text("Host translator (ES 3.0)").tag(true)
    }
    .disabled(!Qemu.hostGLESAvailable && !hostGLES)
    Text(Qemu.hostGLESAvailable
      ? "Try the host translator if a GLES app draws wrong under ANGLE."
      : "This build of Mini lacks the host translator (libshadertranslator), so devices use ANGLE.")
      .font(.caption).foregroundStyle(.secondary)
  }
}
