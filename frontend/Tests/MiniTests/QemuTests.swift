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
  #expect(kv["hardware.gltransport"] == "virtio-gpu-asg" && kv["qemu.adb.pubkey"] == nil && kv["hardwareegl"] == "angle")
}

@Test func hostGLESSwitchesTheGuestDriverAndHostRenderer() {
  var c = DeviceConfig()
  c.hostGLES = true
  let kv = Dictionary(uniqueKeysWithValues: Qemu.bootconfig(avd: "p", config: c, vbmeta: [], adbKey: nil, logcat: false))
  #expect(kv["hardwareegl"] == "emulation")
  let env = Qemu.environment(hostGLES: true)
  #expect(env["ANDROID_EMU_RENDERER"] == "host" && env["DYLD_FALLBACK_LIBRARY_PATH"] == Qemu.root + "/lib")
  #expect(Qemu.environment(hostGLES: false)["DYLD_FALLBACK_LIBRARY_PATH"] == nil)
}

@Test func miniMessagesAreSixteenLittleEndianBytes() {
  #expect(MiniMsg.encode(MiniMsg.touch, 384, 638, 1) == Data([1, 0, 0, 0, 0x80, 1, 0, 0, 0x7e, 2, 0, 0, 1, 0, 0, 0]))
  #expect(MiniMsg.encode(MiniMsg.pointer, 0, 0, 2, arg: -3) == Data([5, 0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0]))
}

@Test func wheelLinesBecomeWholeNotches() {
  #expect(ScreenView.notches(0.1) == 1 && ScreenView.notches(-2.2) == -3 && ScreenView.notches(1000) == 127)
}

/// A port some process listens on is taken; Machine.start then moves on to the next pair.
@Test func canListenSeesATakenPort() throws {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  var addr = Qemu.loopback(0)
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  try #require(withUnsafeMutablePointer(to: &addr) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && listen(fd, 1) == 0 && getsockname(fd, $0, &len) == 0 }
  })
  let port = Int(UInt16(bigEndian: addr.sin_port))
  #expect(!Qemu.canListen(port))
  close(fd)
  #expect(Qemu.canListen(port))
}
