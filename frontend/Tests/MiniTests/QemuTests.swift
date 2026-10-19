import Foundation
import Testing
@testable import Mini

/// The kernel finds the bootconfig by its trailer: size, byte-sum checksum, magic (Documentation/admin-guide/bootconfig.rst).
@Test func bootconfigTrailerMatchesKernelFormat() {
  let out = Qemu.appendBootconfig([("hardware", "ranchu"), ("qemu", "1")], to: Data([1, 2, 3]))
  let text = "androidboot.hardware=\"ranchu\"\nandroidboot.qemu=\"1\"\n"
  let padded = Data(text.utf8) + Data(repeating: 0, count: (4 - text.utf8.count % 4) % 4)
  let u32 = { (d: Data) in d.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
  #expect(out.prefix(3) == Data([1, 2, 3]))
  #expect(out.suffix(12) == Data("#BOOTCONFIG\n".utf8))
  #expect(Int(u32(out.dropLast(12).suffix(8).prefix(4))) == padded.count)
  #expect(u32(out.dropLast(12).suffix(4)) == padded.reduce(0) { $0 &+ UInt32($1) })
  #expect(out.dropFirst(3).prefix(padded.count) == padded)
}

@Test func bootconfigTakesVbmetaAndDeviceSettings() {
  var c = DeviceConfig()
  c.freeform = true
  let kv = Dictionary(uniqueKeysWithValues: Qemu.bootconfig(
    avd: "p", config: c, vbmeta: ["androidboot.vbmeta.size=6784", "bogus"], adbKey: nil, logcat: false))
  #expect(kv["vbmeta.size"] == "6784" && kv["qemu.skin"] == "1080x2400" && kv["qemu.display.settings.xml"] == "freeform")
  #expect(kv["hardware.gltransport"] == "virtio-gpu-asg" && kv["qemu.adb.pubkey"] == nil)
}

@Test func miniMessagesAreSixteenLittleEndianBytes() {
  #expect(MiniMsg.encode(MiniMsg.touch, 384, 638, 1) == Data([1, 0, 0, 0, 0x80, 1, 0, 0, 0x7e, 2, 0, 0, 1, 0, 0, 0]))
}
