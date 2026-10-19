import AppKit
import CryptoKit
import SwiftUI

/// Mini's own copy of the Android Emulator, downloaded from Google on first run (its license forbids bundling it).
enum EmulatorSetup {
  // Canary: unlike stable 37.2.x, its gfxstream passes VK_EXT_provoking_vertex through, which guest ANGLE needs for ES 3.x.
  static let version = "37.3.4"
  static let zipURL = URL(string: "https://dl.google.com/android/repository/emulator-darwin_aarch64-16555280.zip")!
  static let sha1 = "4cd3b6f14336a0085b8992eeffe637864839b4ce"
  static let repoURL = URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!
  static let licenseID = "android-sdk-preview-license"  // what repository2-3.xml lists for this package
  static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Mini")
  static let dir = root.path + "/emulator"

  /// True when the pinned version is unpacked; a pin bump makes Mini offer the download again.
  static var installed: Bool {
    let props = try? String(contentsOfFile: dir + "/source.properties", encoding: .utf8)
    return props?.contains("Pkg.Revision=\(version)\n") == true
      && FileManager.default.isExecutableFile(atPath: dir + "/emulator")
  }

  /// License text exactly as Google's SDK repository publishes it, so the user accepts the real terms.
  static func license() async throws -> String {
    let (data, _) = try await URLSession.shared.data(from: repoURL)
    let nodes = try XMLDocument(data: data).nodes(forXPath: "//license[@id='\(licenseID)']")
    guard let text = nodes.first?.stringValue else { throw SetupError("license \(licenseID) missing from \(repoURL)") }
    return text
  }

  /// Downloads into `progress`, verifies the pinned SHA-1, unpacks, and swaps in Mini's MoltenVK.
  static func install(progress: @escaping @MainActor (Progress) -> Void) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let zip = root.appendingPathComponent("emulator.zip"), staging = root.appendingPathComponent("staging")
    defer { try? fm.removeItem(at: zip); try? fm.removeItem(at: staging) }

    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      let task = URLSession.shared.downloadTask(with: zipURL) { tmp, response, error in
        // The temp file is deleted when this handler returns, so move it now.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let tmp, status == 200 else { return cont.resume(throwing: error ?? SetupError("download failed: HTTP \(status)")) }
        try? FileManager.default.removeItem(at: zip)
        cont.resume(with: Result { try FileManager.default.moveItem(at: tmp, to: zip) })
      }
      Task { @MainActor in progress(task.progress) }
      task.resume()
    }

    let actual = try sha1(of: zip)
    guard actual == sha1 else { throw SetupError("checksum mismatch: got \(actual), expected \(sha1)") }

    try? fm.removeItem(at: staging)
    let ditto = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, staging.path])
    ditto.waitUntilExit()
    guard ditto.terminationStatus == 0 else { throw SetupError("unzip failed (ditto exit \(ditto.terminationStatus))") }

    // Google's MoltenVK 1.4.0 lacks VK_EXT_provoking_vertex; ours is built with MVK_USE_METAL_PRIVATE_API (scripts/bundle.sh).
    let unpacked = staging.appendingPathComponent("emulator")
    if let mvk = Bundle.main.url(forResource: "libMoltenVK", withExtension: "dylib") {
      let target = unpacked.appendingPathComponent("lib64/vulkan/libMoltenVK.dylib")
      try fm.removeItem(at: target)
      try fm.copyItem(at: mvk, to: target)
    } else {
      // shortcut: `swift run` has no app bundle, so it keeps Google's MoltenVK (guest ANGLE stays ES 2.0); use bundle.sh for ES 3.1.
      FileHandle.standardError.write(Data("Mini: no bundled libMoltenVK.dylib; keeping the emulator's own\n".utf8))
    }
    try? fm.removeItem(atPath: dir)
    try fm.moveItem(at: unpacked, to: URL(fileURLWithPath: dir))
  }

  static func sha1(of url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hash = Insecure.SHA1()
    while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

struct SetupError: LocalizedError {
  let errorDescription: String?
  init(_ msg: String) { errorDescription = msg }
}

struct SetupView: View {
  let done: () -> Void
  @State private var license: String?
  @State private var progress: Progress?
  @State private var busy = false
  @State private var status: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Mini needs Android Emulator \(EmulatorSetup.version)").font(.headline)
      Text("Google's license doesn't allow bundling the emulator, so Mini downloads it (about 420 MB) from Google into ~/Library/Application Support/Mini. Downloading means accepting these terms:")
        .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        Text(license ?? "Loading license…").font(.caption.monospaced()).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
      .frame(height: 320)
      .background(.background.secondary)
      if let progress { ProgressView(progress) }
      if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
      HStack {
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }
        Button("Accept & Download") { download() }
          .keyboardShortcut(.defaultAction)
          .disabled(license == nil || busy)
      }
    }
    .padding(20)
    .frame(width: 600)
    .task { await loadLicense() }
  }

  private func loadLicense() async {
    do { license = try await EmulatorSetup.license(); status = nil } catch {
      status = "Couldn't load the license: \(error.localizedDescription)"
    }
  }

  private func download() {
    busy = true
    status = nil
    Task {
      do {
        try await EmulatorSetup.install { progress = $0 }
        done()
      } catch {
        busy = false
        progress = nil
        status = "Install failed: \(error.localizedDescription)"
      }
    }
  }
}

@MainActor
enum SetupWindow {
  private static var window: NSWindow?

  static func show(done: @escaping () -> Void) {
    let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView {
      done()  // open the main window first: closing the last window quits Mini
      window?.close()
      window = nil
    }))
    w.title = "Set up Mini"
    w.styleMask = [.titled]  // no close box: Quit or finish, never a windowless app
    w.isReleasedWhenClosed = false
    w.center()
    w.makeKeyAndOrderFront(nil)
    window = w
  }
}
