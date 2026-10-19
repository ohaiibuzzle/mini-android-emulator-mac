import AppKit
import SwiftUI

/// User options (UserDefaults).
enum Prefs {
  static let debugLogs = "debugLogs"
  static let avd = "avd"

  /// Mini's folder: system images and platform-tools in the SDK's layout, devices under Devices/. MINI_HOME is for tests.
  static var home: String {
    ProcessInfo.processInfo.environment["MINI_HOME"]
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mini").path
  }
  static var devices: String { home + "/Devices" }

  /// Device names: the directories under Devices/ that have a config.ini.
  static func avds() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: devices)) ?? []
    return names.filter { FileManager.default.fileExists(atPath: configPath(avd: $0)) }.sorted()
  }

  /// The device's hardware config, in the emulator's config.ini keys.
  static func configPath(avd: String) -> String { "\(devices)/\(avd)/config.ini" }

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
      debugLogs: false, avd: avds().first ?? "",
    ])
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

  // Guards against typos the guest would only reject at boot.
  var valid: Bool { (320...7680).contains(width) && (320...7680).contains(height) && (120...640).contains(density) }
}

struct SettingsView: View {
  @AppStorage(Prefs.debugLogs) var debugLogs = false

  var body: some View {
    Form {
      Toggle("Kernel console and logcat logs", isOn: $debugLogs)
      Text("Changes apply the next time a device starts. Devices and their screens are in Devices (⇧⌘D).")
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
