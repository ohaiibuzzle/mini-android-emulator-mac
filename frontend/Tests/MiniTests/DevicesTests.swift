import Foundation
import Testing
@testable import Mini

@MainActor @Test func createWritesPointerAndConfig() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent("mini-avd-\(getpid())").path
  setenv("ANDROID_AVD_HOME", home, 1)
  defer { unsetenv("ANDROID_AVD_HOME"); try? FileManager.default.removeItem(atPath: home) }
  let image = SystemImage(sysdir: "system-images/android-37.0/gsi_x/arm64-v8a/", props: ["SystemImage.TagId": "gsi_x", "SystemImage.TagDisplay": "X"])
  var c = DeviceConfig()
  c.freeform = true
  try Devices.create(name: "t1", image: image, config: c)
  #expect(Prefs.avds() == ["t1"])
  let ini = Prefs.ini(try String(contentsOfFile: Prefs.configPath(avd: "t1"), encoding: .utf8))
  #expect(ini["image.sysdir.1"] == image.sysdir && ini["target"] == "android-37.0" && ini["hw.keyboard"] == "yes")
  #expect(DeviceConfig.load(avd: "t1") == { var e = c; e.sysdir = image.sysdir; return e }())
  #expect(throws: SetupError.self) { try Devices.create(name: "t1", image: image, config: c) }
  #expect(!Devices.validName("a b") && !Devices.validName("") && Devices.validName("Lineage-24.0_x"))
}
