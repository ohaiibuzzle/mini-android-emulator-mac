import AppKit
import SwiftUI

/// User options (UserDefaults). Everything that costs performance is off by default.
enum Prefs {
  static let gles = "gles"  // "angle" | "translator"
  static let audio = "audio"
  static let radios = "radios"
  static let cameras = "cameras"
  static let debugLogs = "debugLogs"
  static let avd = "avd"

  static var sdk: String { ProcessInfo.processInfo.environment["ANDROID_HOME"] ?? NSHomeDirectory() + "/Library/Android/sdk" }
  static var avdHome: String { ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"] ?? NSHomeDirectory() + "/.android/avd" }

  /// AVD names from the avd home (`*.ini` next to each `*.avd` directory).
  static func avds() -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: avdHome)) ?? []
    return files.filter { $0.hasSuffix(".ini") }.map { String($0.dropLast(4)) }.sorted()
  }

  /// The AVD's own hardware config; `<name>.ini` says where its directory is.
  static func configPath(avd: String) -> String {
    let pointer = try? String(contentsOfFile: "\(avdHome)/\(avd).ini", encoding: .utf8)
    let dir = pointer.flatMap { ini($0)["path"] } ?? "\(avdHome)/\(avd).avd"
    return dir + "/config.ini"
  }

  static func ini(_ text: String) -> [String: String] {
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") {
      guard let eq = line.firstIndex(of: "=") else { continue }
      out[line[..<eq].trimmingCharacters(in: .whitespaces)] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    }
    return out
  }

  /// `text` with `values` replacing their keys' lines (appended when missing, removed when nil); other lines are untouched.
  static func ini(_ text: String, setting values: [String: String?]) -> String {
    var pending = values
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line -> String? in
      guard let eq = line.firstIndex(of: "="),
        let v = pending.removeValue(forKey: line[..<eq].trimmingCharacters(in: .whitespaces))
      else { return String(line) }
      return v.map { "\(line[..<eq])=\($0)" }
    }
    if lines.last == "" { lines.removeLast() }
    lines += pending.keys.sorted().compactMap { k in pending[k]!.map { "\(k)=\($0)" } }
    return lines.joined(separator: "\n") + "\n"
  }

  static func register() {
    UserDefaults.standard.register(defaults: [
      gles: "angle", audio: false, radios: false, cameras: false, debugLogs: false, avd: avds().first ?? "",
    ])
  }

  /// Emulator command line for the current settings.
  static func emulatorArgs(avd: String, grpcPort: Int) -> [String] {
    let d = UserDefaults.standard
    var args = ["-avd", avd, "-no-window", "-gpu", "host", "-grpc", "\(grpcPort)", "-grpc-use-token"]
    var features: [String] = []
    // ANGLE: guest GLES on ANGLE over gfxstream Vulkan (MoltenVK). Translator: host GLES→desktop GL.
    if d.string(forKey: gles) == "angle" { features.append("GuestUsesAngle") }
    if !d.bool(forKey: audio) { args.append("-no-audio") }
    if !d.bool(forKey: radios) {
      // Wi-Fi stays: the guest's only internet route is virtio-wifi. These drop netsimd (BT/UWB) and the modem.
      features += ["-BluetoothEmulation", "-Uwb", "-ModemSimulator", "-WiFiPacketStream"]
    }
    if !d.bool(forKey: cameras) { args += ["-camera-back", "none", "-camera-front", "none"] }
    if d.bool(forKey: debugLogs) { args += ["-show-kernel", "-logcat", "*:w"] }
    if !features.isEmpty { args += ["-feature", features.joined(separator: ",")] }
    return args
  }
}

/// Guest screen size (config.ini hw.lcd.*).
struct DisplaySize: Hashable {
  var width = 1080, height = 2400, density = 420
  static let presets: [(String, DisplaySize)] = [
    ("Phone", DisplaySize(width: 1080, height: 2400, density: 420)),
    ("Tablet", DisplaySize(width: 2560, height: 1600, density: 320)),
    ("Desktop", DisplaySize(width: 2560, height: 1440, density: 240)),
  ]

  // Guards against typos the emulator would only reject at boot.
  var valid: Bool { (320...7680).contains(width) && (320...7680).contains(height) && (120...640).contains(density) }
}

struct SettingsView: View {
  @AppStorage(Prefs.gles) var gles = "angle"
  @AppStorage(Prefs.audio) var audio = false
  @AppStorage(Prefs.radios) var radios = false
  @AppStorage(Prefs.cameras) var cameras = false
  @AppStorage(Prefs.debugLogs) var debugLogs = false

  var body: some View {
    Form {
      Picker("OpenGL ES", selection: $gles) {
        Text("ANGLE in guest (Vulkan → MoltenVK)").tag("angle")
        Text("Host translator (desktop GL)").tag("translator")
      }
      Toggle("Audio", isOn: $audio)
      Toggle("Radios (Bluetooth, UWB, cellular modem)", isOn: $radios)
      Toggle("Cameras", isOn: $cameras)
      Toggle("Kernel console and logcat in emulator log", isOn: $debugLogs)
      Text("Changes apply the next time the emulator starts. Devices and their screens are in Devices (⇧⌘D).")
        .font(.caption).foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize()
  }
}

@MainActor
enum SettingsWindow {
  private static var window: NSWindow?

  static func show() {
    if window == nil {
      let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
      w.title = "Mini Settings"
      w.styleMask = [.titled, .closable]
      w.isReleasedWhenClosed = false
      window = w
    }
    window?.center()
    window?.makeKeyAndOrderFront(nil)
  }
}
