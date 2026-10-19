import AppKit
import CryptoKit
import SwiftUI

/// A pinned zip from Google's SDK repository. Its license forbids bundling, so Mini shows the terms and downloads it.
struct SDKDownload: Sendable {
  let title: String  // "Android Emulator 37.3.4"
  let blurb: String  // why and where, shown above the license
  let zipURL: URL
  let sha1: String
  let repoURL: URL  // repository XML that publishes the license text
  let licenseID: String

  /// License text exactly as Google's SDK repository publishes it, so the user accepts the real terms.
  func license() async throws -> String {
    let (data, _) = try await URLSession.shared.data(from: repoURL)
    let nodes = try XMLDocument(data: data).nodes(forXPath: "//license[@id='\(licenseID)']")
    guard let text = nodes.first?.stringValue else { throw SetupError("license \(licenseID) missing from \(repoURL)") }
    return text
  }

  /// Downloads next to `dest`, verifies the pinned SHA-1, unzips, lets `prepare` adjust the zip's single
  /// top-level directory, then moves it to `dest` (replacing what's there).
  func install(
    to dest: URL, progress: @escaping @MainActor (Progress) -> Void, prepare: (URL) throws -> Void = { _ in }
  ) async throws {
    let fm = FileManager.default
    let parent = dest.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    // Staged on dest's volume so the final move is a rename, not a multi-GB copy.
    let zip = parent.appendingPathComponent(".mini-download.zip"), staging = parent.appendingPathComponent(".mini-staging")
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

    let actual = try EmulatorSetup.sha1(of: zip)
    guard actual == sha1 else { throw SetupError("checksum mismatch: got \(actual), expected \(sha1)") }

    try? fm.removeItem(at: staging)
    let ditto = try Process.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, staging.path])
    ditto.waitUntilExit()
    guard ditto.terminationStatus == 0 else { throw SetupError("unzip failed (ditto exit \(ditto.terminationStatus))") }
    let top = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).filter { $0.hasDirectoryPath }
    guard top.count == 1 else { throw SetupError("expected one top-level directory in \(zipURL.lastPathComponent)") }
    try prepare(top[0])
    try? fm.removeItem(at: dest)
    try fm.moveItem(at: top[0], to: dest)
  }
}

/// Mini's own copy of the Android Emulator, downloaded from Google on first run.
enum EmulatorSetup {
  // Canary: unlike stable 37.2.x, its gfxstream passes VK_EXT_provoking_vertex through, which guest ANGLE needs for ES 3.x.
  static let version = "37.3.4"
  static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Mini")
  static let dir = root.path + "/emulator"
  static let download = SDKDownload(
    title: "Android Emulator \(version)",
    blurb: "Google's license doesn't allow bundling the emulator, so Mini downloads it (about 420 MB) from Google into ~/Library/Application Support/Mini. Downloading means accepting these terms:",
    zipURL: URL(string: "https://dl.google.com/android/repository/emulator-darwin_aarch64-16555280.zip")!,
    sha1: "4cd3b6f14336a0085b8992eeffe637864839b4ce",
    repoURL: URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!,
    licenseID: "android-sdk-preview-license")  // what repository2-3.xml lists for this package

  /// True when the pinned version is unpacked; a pin bump makes Mini offer the download again.
  static var installed: Bool {
    let props = try? String(contentsOfFile: dir + "/source.properties", encoding: .utf8)
    return props?.contains("Pkg.Revision=\(version)\n") == true
      && FileManager.default.isExecutableFile(atPath: dir + "/emulator")
  }

  /// Downloads into `progress`, verifies, unpacks, and swaps in Mini's MoltenVK.
  static func install(progress: @escaping @MainActor (Progress) -> Void) async throws {
    try await download.install(to: URL(fileURLWithPath: dir), progress: progress) { unpacked in
      // Google's MoltenVK 1.4.0 lacks VK_EXT_provoking_vertex; ours is built with MVK_USE_METAL_PRIVATE_API (scripts/bundle.sh).
      if let mvk = Bundle.main.url(forResource: "libMoltenVK", withExtension: "dylib") {
        let target = unpacked.appendingPathComponent("lib64/vulkan/libMoltenVK.dylib")
        try FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: mvk, to: target)
      } else {
        // shortcut: `swift run` has no app bundle, so it keeps Google's MoltenVK (guest ANGLE stays ES 2.0); use bundle.sh for ES 3.1.
        FileHandle.standardError.write(Data("Mini: no bundled libMoltenVK.dylib; keeping the emulator's own\n".utf8))
      }
    }
  }

  static func sha1(of url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hash = Insecure.SHA1()
    while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// Google's stock API 37 image: what new devices boot by default and what Import GSI borrows kernel and vendor from.
enum BaseImage {
  static let sysdir = "system-images/android-37.0/google_apis/arm64-v8a/"
  static var dir: String { Prefs.sdk + "/" + sysdir }
  static let download = SDKDownload(
    title: "Google APIs system image (Android 17, API 37)",
    blurb: "New devices and imported GSIs boot on Google's stock image: its kernel, vendor and ramdisk. Mini downloads it (about 2.2 GB, 6 GB unpacked) from Google into your Android SDK's system-images, where sdkmanager would put it. Downloading means accepting these terms:",
    zipURL: URL(string: "https://dl.google.com/android/repository/sys-img/google_apis/arm64-v8a-37.0_r06.zip")!,
    sha1: "e007fb23024c59bffdf944b95c61143bc38101ce",
    repoURL: URL(string: "https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-4.xml")!,
    licenseID: "android-sdk-arm-dbt-license")  // what sys-img2-4.xml lists for this package

  static var installed: Bool {
    ["system.img", "vendor.img", "ramdisk.img", "kernel-ranchu"].allSatisfy { FileManager.default.fileExists(atPath: dir + $0) }
  }

  static func install(progress: @escaping @MainActor (Progress) -> Void) async throws {
    // shortcut: no package.xml, so sdkmanager lists it as unknown; write one if Android Studio interop matters.
    try await download.install(to: URL(fileURLWithPath: dir), progress: progress)
  }
}

struct SetupError: LocalizedError {
  let errorDescription: String?
  init(_ msg: String) { errorDescription = msg }
}

struct SetupView: View {
  let download: SDKDownload
  let install: (@escaping @MainActor (Progress) -> Void) async throws -> Void
  let cancelTitle: String
  let cancel: () -> Void
  let done: () -> Void
  @State private var license: String?
  @State private var progress: Progress?
  @State private var busy = false
  @State private var status: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Mini needs \(download.title)").font(.headline)
      Text(download.blurb).fixedSize(horizontal: false, vertical: true)
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
        Button(cancelTitle, action: cancel).disabled(busy && cancelTitle != "Quit")
        Button("Accept & Download") { start() }
          .keyboardShortcut(.defaultAction)
          .disabled(license == nil || busy)
      }
    }
    .padding(20)
    .frame(width: 600)
    .task { await loadLicense() }
  }

  private func loadLicense() async {
    do { license = try await download.license(); status = nil } catch {
      status = "Couldn't load the license: \(error.localizedDescription)"
    }
  }

  private func start() {
    busy = true
    status = nil
    Task {
      do {
        try await install { progress = $0 }
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

  /// First-run emulator download. No close box: Quit or finish, never a windowless app.
  static func show(done: @escaping () -> Void) {
    present(EmulatorSetup.download, install: EmulatorSetup.install, cancelTitle: "Quit", cancel: { NSApp.terminate(nil) },
            closable: false, done: done)
  }

  /// Base-image download, offered when a device or GSI import needs it.
  static func showBaseImage(done: @escaping () -> Void) {
    present(BaseImage.download, install: BaseImage.install, cancelTitle: "Cancel", cancel: close, closable: true, done: done)
  }

  private static func present(
    _ download: SDKDownload, install: @escaping (@escaping @MainActor (Progress) -> Void) async throws -> Void,
    cancelTitle: String, cancel: @escaping () -> Void, closable: Bool, done: @escaping () -> Void
  ) {
    close()
    let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(
      download: download, install: install, cancelTitle: cancelTitle, cancel: cancel
    ) {
      done()  // open the next window first: closing the last window quits Mini
      close()
    }))
    w.title = "Download \(download.title)"
    w.styleMask = closable ? [.titled, .closable] : [.titled]
    w.isReleasedWhenClosed = false
    w.center()
    w.makeKeyAndOrderFront(nil)
    window = w
  }

  private static func close() {
    window?.close()
    window = nil
  }
}
