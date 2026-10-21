import AppKit
import GameController

/// Mac game controllers drive the key device window's virtio-gamepad (third_party/qemu/hw/input/virtio-input-gamepad.c),
/// with the evdev codes Linux's xpad driver uses for an Xbox 360 pad. Every controller drives the one pad.
@MainActor
enum Gamepad {
  typealias Event = (type: Int8, code: Int32, value: Int32)

  static let rest = events(GCController.withExtendedGamepad().extendedGamepad!)
  static let syn: Event = (0, 0, 0)

  static func start() {
    let center = NotificationCenter.default
    // Handlers run on the main queue, GCController's default. Setting every controller's again is harmless.
    center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated {
        for c in GCController.controllers() {
          c.extendedGamepad?.valueChangedHandler = { pad, _ in MainActor.assumeIsolated { target?.pad(events(pad)) } }
        }
      }
    }
    // A pad unplugged mid-press would leave the guest holding it.
    center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { target?.pad(rest) }
    }
  }

  private static var target: ScreenView? { NSApp.keyWindow?.contentView as? ScreenView }

  /// The whole pad's state as evdev events. Y axes point down in evdev, up in GameController.
  nonisolated static func events(_ pad: GCExtendedGamepad) -> [Event] {
    let key = { (code: Int32, b: GCControllerButtonInput?) in (Int8(1), code, Int32(b?.isPressed == true ? 1 : 0)) }
    let abs = { (code: Int32, v: Float, max: Float) in (Int8(3), code, Int32((v * max).rounded())) }
    return [
      key(304, pad.buttonA), key(305, pad.buttonB), key(307, pad.buttonX), key(308, pad.buttonY),
      key(310, pad.leftShoulder), key(311, pad.rightShoulder), key(314, pad.buttonOptions), key(315, pad.buttonMenu),
      key(316, pad.buttonHome), key(317, pad.leftThumbstickButton), key(318, pad.rightThumbstickButton),
      abs(0x00, pad.leftThumbstick.xAxis.value, 32767), abs(0x01, -pad.leftThumbstick.yAxis.value, 32767),
      abs(0x03, pad.rightThumbstick.xAxis.value, 32767), abs(0x04, -pad.rightThumbstick.yAxis.value, 32767),
      abs(0x02, pad.leftTrigger.value, 255), abs(0x05, pad.rightTrigger.value, 255),
      abs(0x10, pad.dpad.xAxis.value, 1), abs(0x11, -pad.dpad.yAxis.value, 1),
    ]
  }
}
