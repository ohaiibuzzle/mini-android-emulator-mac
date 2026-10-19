import Foundation
import Testing
@testable import Mini

/// The kernel's HCI setup and Android's stack parse these events byte for byte, so the lengths matter.
@Test func bluetoothResetIsTheSixByteComplete() {
  #expect(Bluetooth.Controller.event(for: 0x0c03) == [0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00])
}

@Test func bluetoothReadCommandsAnswerTheirParseLengths() {
  let version = Bluetooth.Controller.event(for: 0x1001)
  #expect(version.count == 6 + 9)  // type, event, len, packets, opcode (2), then status + 8
  #expect(version[2] == 12)  // parameter length: packets, opcode and the 9 return bytes

  let commands = Bluetooth.Controller.event(for: 0x1002)
  #expect(commands[2] == UInt8(3 + 65))
  #expect(commands.count == 6 + 65)

  let buffers = Bluetooth.Controller.event(for: 0x1005)
  #expect(buffers[2] == UInt8(3 + 8))
  #expect(buffers.count == 6 + 8)
}

/// Android's Gd controller aborts (ASSERT) when these views don't parse, so their return lengths are load-bearing.
@Test func bluetoothLeReadsCarryTheirExactReturnLengths() {
  // opcode: return parameter count (including status) after the 3-byte complete header.
  let expected: [UInt16: Int] = [
    0x1001: 9, 0x1002: 65, 0x1003: 9, 0x1004: 11, 0x1005: 8, 0x1009: 7,
    0x2002: 4, 0x2003: 9, 0x201c: 9, 0x200f: 2, 0x2007: 2, 0x2018: 9,
  ]
  for (opcode, count) in expected {
    let event = Bluetooth.Controller.event(for: opcode)
    #expect(event[2] == UInt8(count + 3), "\(String(opcode, radix: 16))")
    #expect(event.count == 6 + count, "\(String(opcode, radix: 16))")
  }
  // Page 0, max page 0, and the SSP bit (features byte 6, 0x08) that btm_sec_dev_reset asserts on.
  let extended = Bluetooth.Controller.event(for: 0x1004)
  #expect(extended[7] == 0x00 && extended[8] == 0x00)  // page, max page
  #expect(Array(extended[9..<15]).allSatisfy { $0 == 0 })
  #expect(extended[15] == 0x08 && extended[16] == 0x00)
}

@Test func bluetoothH4SkipsOtherPacketsAndWaitsForTheRest() {
  var bytes: [UInt8] = [0x01, 0x03, 0x0c]  // partial Reset
  #expect({ if case nil = Bluetooth.H4.next(&bytes) { return true } else { return false } }())
  bytes += [0x00]
  let packet = Bluetooth.H4.next(&bytes)
  guard case .command(let opcode, let parameters)? = packet else { Issue.record("expected a command"); return }
  #expect(opcode == 0x0c03)
  #expect(parameters.isEmpty)
  #expect(bytes.isEmpty)

  // An ACL packet (type 2) is skipped as one unit, leaving the next command for the parser.
  bytes = [0x02, 0x01, 0x00, 0x02, 0x00, 0xaa, 0xbb, 0x01, 0x03, 0x0c, 0x00]
  #expect({ if case .other? = Bluetooth.H4.next(&bytes) { return true } else { return false } }())
  guard case .command(let nextOpcode, _)? = Bluetooth.H4.next(&bytes) else { Issue.record("expected Reset"); return }
  #expect(nextOpcode == 0x0c03)
}
