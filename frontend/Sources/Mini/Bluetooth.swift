import Foundation

/// A dummy Bluetooth controller for QEMU's Bluetooth virtio-console port.
///
/// The guest's `bt_vhci_forwarder` bridges `/dev/vhci` to that port as H4. With nothing answering on the host side,
/// the kernel's HCI setup never completes, so `hci0` stays hidden from mgmt and Android's Bluetooth HAL busy-loops
/// in `waitHciDev`. This answers the handful of commands that the kernel's setup and Android's stack need. It is a
/// Classic-only controller: no LE, no connections, no devices. That is enough for Bluetooth to switch on and idle.
enum Bluetooth {
  /// Answers the forwarder until QEMU goes away.
  static func run(socket: String) async throws {
    let link = try await Qemu.connect(socket)
    // Its own thread: this blocking read must not share a queue with anything else.
    Thread.detachNewThread {
      var pending: [UInt8] = []
      var buf = [UInt8](repeating: 0, count: 4096)
      while case let n = read(link.fileDescriptor, &buf, buf.count), n > 0 {
        pending += buf[..<n]
        while let packet = H4.next(&pending) {
          if case .command(let opcode, _) = packet {
            try? link.write(contentsOf: Data(Controller.event(for: opcode)))
          }
        }
      }
    }
  }

  /// H4 framing. The guest only sends commands (the host is the controller), so the other types are skipped.
  enum H4 {
    enum Packet { case command(opcode: UInt16, parameters: [UInt8]), other }

    /// Removes and returns the next complete packet; nil when `bytes` holds only a partial one.
    static func next(_ bytes: inout [UInt8]) -> Packet? {
      while let type = bytes.first {
        switch type {
        case 0x01:  // command: type, opcode (2), parameter length (1), parameters
          guard bytes.count >= 4 else { return nil }
          let count = Int(bytes[3])
          guard bytes.count >= 4 + count else { return nil }
          let opcode = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
          let parameters = Array(bytes[4..<4 + count])
          bytes.removeFirst(4 + count)
          return .command(opcode: opcode, parameters: parameters)
        case 0x02:  // ACL: type, handle/flags (2), length (2)
          guard bytes.count >= 5 else { return nil }
          let count = Int(bytes[3]) | Int(bytes[4]) << 8
          guard bytes.count >= 5 + count else { return nil }
          bytes.removeFirst(5 + count)
          return .other
        case 0x03:  // SCO: type, handle/flags (2), length (1)
          guard bytes.count >= 4 else { return nil }
          let count = Int(bytes[3])
          guard bytes.count >= 4 + count else { return nil }
          bytes.removeFirst(4 + count)
          return .other
        case 0x05:  // ISO: type, handle/flags (2), length (2)
          guard bytes.count >= 5 else { return nil }
          let count = (Int(bytes[3]) | Int(bytes[4]) << 8) & 0x3fff
          guard bytes.count >= 5 + count else { return nil }
          bytes.removeFirst(5 + count)
          return .other
        default:
          // Events never travel this way; drop the byte and look for a packet type.
          bytes.removeFirst()
        }
      }
      return nil
    }
  }

  /// The controller's command responses, as H4-framed events.
  enum Controller {
    /// Everything the kernel's HCI init and Android's stack read during power-on. Anything else is a "set" command
    /// from the stack's point of view, so an empty Command Complete (success) is the right answer. Commands whose
    /// return parameters matter must carry the lengths the callers parse.
    static func event(for opcode: UInt16) -> [UInt8] {
      switch opcode {
      case 0x0c03:  // Reset
        return complete(opcode, [0x00])
      case 0x1001:  // Read Local Version Information
        return complete(opcode, [0x00, 0x06, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00])
      case 0x1002:  // Read Local Supported Commands
        return complete(opcode, [0x00] + zeros(64))
      case 0x1003:  // Read Local Supported Features
        return complete(opcode, [0x00] + zeros(8))  // no LE, baseline BR/EDR
      case 0x1005:  // Read Buffer Size
        return complete(opcode, [0x00, 0x00, 0x04, 0x08, 0x0a, 0x00, 0x0a, 0x00])  // 1024, 8, 10, 10
      case 0x1009:  // Read BD_ADDR
        return complete(opcode, [0x00, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22])
      case 0x0c14:  // Read Local Name
        return complete(opcode, [0x00] + name)
      case 0x1004:  // Read Local Extended Features (page 0)
        // Bit 51 (byte 6, 0x08): Secure Simple Pairing. btm_sec_dev_reset asserts on its absence.
        return complete(opcode, [0x00, 0x00, 0x00] + zeros(6) + [0x08, 0x00])
      case 0x0c23:  // Read Class of Device
        return complete(opcode, [0x00, 0x00, 0x00, 0x00])
      case 0x0c25:  // Read Voice Setting
        return complete(opcode, [0x00, 0x00, 0x00])
      case 0x0c38:  // Read Number of Supported IAC
        return complete(opcode, [0x00, 0x01])
      case 0x0c39:  // Read Current IAC LAP
        return complete(opcode, [0x00, 0x01, 0x33, 0x8b, 0x9e])  // one GIAC
      // Android's stack reads these LE values even when the controller doesn't advertise LE, and aborts on a
      // command complete whose view doesn't parse, so their return lengths matter.
      case 0x2002:  // LE Read Buffer Size
        return complete(opcode, [0x00, 0xfb, 0x00, 0x10])  // 251, 16
      case 0x2007:  // LE Read Advertising Physical Channel Tx Power
        return complete(opcode, [0x00, 0x00])
      case 0x2003:  // LE Read Local Supported Features
        return complete(opcode, [0x00] + zeros(8))
      case 0x201c:  // LE Read Supported States
        return complete(opcode, [0x00] + zeros(8))
      case 0x200f:  // LE Read Filter Accept List Size
        return complete(opcode, [0x00, 0x08])
      case 0x2018:  // LE Rand
        return complete(opcode, [0x00] + (0..<8).map { _ in UInt8.random(in: 0...255) })
      default:
        return complete(opcode, [0x00])
      }
    }

    /// Command Complete: event type, event code, parameter length, packets, opcode, status and return parameters.
    private static func complete(_ opcode: UInt16, _ parameters: [UInt8]) -> [UInt8] {
      [0x04, 0x0e, UInt8(parameters.count + 3), 0x01, UInt8(opcode & 0xff), UInt8(opcode >> 8)] + parameters
    }

    private static let name = Array("Mini".utf8) + zeros(248 - 4)

    private static func zeros(_ count: Int) -> [UInt8] { [UInt8](repeating: 0, count: count) }
  }
}
