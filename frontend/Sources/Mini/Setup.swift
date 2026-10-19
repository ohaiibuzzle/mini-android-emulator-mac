import AppKit
import CryptoKit
import SwiftUI

/// A pinned zip from Google's SDK repository. Its license forbids bundling, so Mini shows the terms and downloads it.
struct SDKDownload: Sendable {
  let title: String  // "Android SDK Platform-Tools 37.0.1"
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
    to dest: URL, progress: @escaping @MainActor (Double) -> Void, prepare: (URL) throws -> Void = { _ in }
  ) async throws {
    let fm = FileManager.default
    let parent = dest.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    // Staged on dest's volume so the final move is a rename, not a multi-GB copy.
    let zip = parent.appendingPathComponent(".mini-download.zip"), staging = parent.appendingPathComponent(".mini-staging")
    defer { try? fm.removeItem(at: zip); try? fm.removeItem(at: staging) }
    // Only a fraction crosses to the UI, on the main actor: SwiftUI's ProgressView(Progress) observes it with Combine,
    // which crashed when CFNetwork updated the task's Progress from its own thread mid-download.
    var observation: NSKeyValueObservation?
    defer { observation?.invalidate() }

    // Asked for gzip, dl.google.com re-compresses the zip on the fly and sends the gzipped length, so URLSession can't
    // know the size and its progress races to the end on a made-up curve.
    var request = URLRequest(url: zipURL)
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      let task = URLSession.shared.downloadTask(with: request) { tmp, response, error in
        // The temp file is deleted when this handler returns, so move it now.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let tmp, status == 200 else { return cont.resume(throwing: error ?? SetupError("download failed: HTTP \(status)")) }
        try? FileManager.default.removeItem(at: zip)
        cont.resume(with: Result { try FileManager.default.moveItem(at: tmp, to: zip) })
      }
      observation = task.progress.observe(\.fractionCompleted) { p, _ in
        let fraction = p.fractionCompleted
        Task { @MainActor in progress(fraction) }
      }
      task.resume()
    }

    let actual = try Self.sha1(of: zip)
    guard actual == sha1 else { throw SetupError("checksum mismatch: got \(actual), expected \(sha1)") }

    try? fm.removeItem(at: staging)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    // bsdtar (libarchive), not ditto: ditto loses its place after a ZIP64 entry (system.img is 4.4 GB).
    let unzip = try Process.run(URL(fileURLWithPath: "/usr/bin/bsdtar"), arguments: ["-xf", zip.path, "-C", staging.path])
    unzip.waitUntilExit()
    guard unzip.terminationStatus == 0 else { throw SetupError("unzip failed (bsdtar exit \(unzip.terminationStatus))") }
    let top = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).filter { $0.hasDirectoryPath }
    guard top.count == 1 else { throw SetupError("expected one top-level directory in \(zipURL.lastPathComponent)") }
    try prepare(top[0])
    try? fm.removeItem(at: dest)
    try fm.moveItem(at: top[0], to: dest)
  }

  static func sha1(of url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    var hash = Insecure.SHA1()
    while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

/// Google's adb, which Mini drives the guest with (GuestSetup). Same license as the emulator: downloaded, never bundled.
enum PlatformTools {
  static var dir: String { Prefs.home + "/platform-tools" }
  static let download = SDKDownload(
    title: "Android SDK Platform-Tools 37.0.1",
    blurb: "Mini talks to Android through Google's adb, and Google's license doesn't allow bundling it, so Mini downloads platform-tools (about 16 MB) from Google into ~/Library/Application Support/Mini. Downloading means accepting these terms:",
    zipURL: URL(string: "https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip")!,
    sha1: "6ae73f4de6452dc57e62ec02b68eed92a4c21661",
    repoURL: URL(string: "https://dl.google.com/android/repository/repository2-3.xml")!,
    licenseID: "android-sdk-license")  // what repository2-3.xml lists for this package

  static var installed: Bool { FileManager.default.isExecutableFile(atPath: dir + "/adb") }

  static func install(progress: @escaping @MainActor (Double) -> Void) async throws {
    try await download.install(to: URL(fileURLWithPath: dir), progress: progress)
  }
}

/// Google's stock API 37 image: what new devices boot by default and what Import GSI borrows kernel and vendor from.
enum BaseImage {
  static let sysdir = "system-images/android-37.0/google_apis/arm64-v8a/"
  static var dir: String { Prefs.home + "/" + sysdir }
  static let download = SDKDownload(
    title: "Google APIs system image (Android 17, API 37)",
    blurb: "New devices and imported GSIs boot on Google's stock image: its kernel, vendor and ramdisk. Mini downloads it (about 2.2 GB, 6 GB unpacked) from Google into ~/Library/Application Support/Mini. Downloading means accepting these terms:",
    zipURL: URL(string: "https://dl.google.com/android/repository/sys-img/google_apis/arm64-v8a-37.0_r06.zip")!,
    sha1: "e007fb23024c59bffdf944b95c61143bc38101ce",
    repoURL: URL(string: "https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-4.xml")!,
    licenseID: "android-sdk-arm-dbt-license")  // what sys-img2-4.xml lists for this package

  static var installed: Bool {
    ["system.img", "vendor.img", "ramdisk.img", "kernel-ranchu"].allSatisfy { FileManager.default.fileExists(atPath: dir + $0) }
  }

  static func install(progress: @escaping @MainActor (Double) -> Void) async throws {
    try await download.install(to: URL(fileURLWithPath: dir), progress: progress)
  }
}

struct SetupError: LocalizedError {
  let errorDescription: String?
  init(_ msg: String) { errorDescription = msg }
}

struct SetupView: View {
  let download: SDKDownload
  let install: (@escaping @MainActor (Double) -> Void) async throws -> Void
  let cancelTitle: String
  let cancel: () -> Void
  let done: () -> Void
  @State private var license: String?
  @State private var progress: Double?
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
      if let progress { ProgressView(value: progress) }
      if progress == 1 { Text("Verifying and unpacking…").font(.caption).foregroundStyle(.secondary) }
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

  /// First-run platform-tools download. No close box: Quit or finish, never a windowless app.
  static func show(done: @escaping () -> Void) {
    present(PlatformTools.download, install: PlatformTools.install, cancelTitle: "Quit", cancel: { NSApp.terminate(nil) },
            closable: false, done: done)
  }

  /// Base-image download, offered when a device or GSI import needs it.
  static func showBaseImage(done: @escaping () -> Void) {
    present(BaseImage.download, install: BaseImage.install, cancelTitle: "Cancel", cancel: close, closable: true, done: done)
  }

  private static func present(
    _ download: SDKDownload, install: @escaping (@escaping @MainActor (Double) -> Void) async throws -> Void,
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
