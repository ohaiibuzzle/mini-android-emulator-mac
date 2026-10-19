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

  /// AVD names from the avd home (`*.ini` next to each `*.avd` directory).
  static func avds() -> [String] {
    let env = ProcessInfo.processInfo.environment
    let dir = env["ANDROID_AVD_HOME"] ?? NSHomeDirectory() + "/.android/avd"
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return files.filter { $0.hasSuffix(".ini") }.map { String($0.dropLast(4)) }.sorted()
  }

  static func register() {
    UserDefaults.standard.register(defaults: [
      gles: "angle", audio: false, radios: false, cameras: false, debugLogs: false, avd: avds().first ?? "",
    ])
  }

  /// Emulator command line for the current settings.
  static func emulatorArgs(avd: String, grpcPort: Int) -> [String] {
    let d = UserDefaults.standard
    var args = ["-avd", avd, "-no-window", "-gpu", "host", "-grpc", "\(grpcPort)", "-grpc-use-token", "-no-boot-anim"]
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

struct SettingsView: View {
  @AppStorage(Prefs.gles) var gles = "angle"
  @AppStorage(Prefs.audio) var audio = false
  @AppStorage(Prefs.radios) var radios = false
  @AppStorage(Prefs.cameras) var cameras = false
  @AppStorage(Prefs.debugLogs) var debugLogs = false
  @AppStorage(Prefs.avd) var avd = ""

  var body: some View {
    Form {
      Picker("Device (AVD)", selection: $avd) {
        ForEach(Prefs.avds(), id: \.self) { Text($0).tag($0) }
      }
      Picker("OpenGL ES", selection: $gles) {
        Text("ANGLE in guest (Vulkan → MoltenVK)").tag("angle")
        Text("Host translator (desktop GL)").tag("translator")
      }
      Toggle("Audio", isOn: $audio)
      Toggle("Radios (Bluetooth, UWB, cellular modem)", isOn: $radios)
      Toggle("Cameras", isOn: $cameras)
      Toggle("Kernel console and logcat in emulator log", isOn: $debugLogs)
      Text("Changes apply the next time the emulator starts. The quick-boot snapshot is discarded when hardware changes.")
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
