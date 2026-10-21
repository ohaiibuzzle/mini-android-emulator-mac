import GameController
import Testing

@testable import Mini

/// GameController's pad → xpad's evdev codes and ranges, Y axes flipped.
@Test @MainActor func gamepadEvents() {
  #expect(Gamepad.rest.allSatisfy { $0.value == 0 })
  let pad = GCController.withExtendedGamepad().extendedGamepad!
  pad.buttonX.setValue(1)
  pad.leftThumbstick.setValueForXAxis(1, yAxis: 1)
  pad.rightTrigger.setValue(0.5)
  pad.dpad.setValueForXAxis(0, yAxis: -1)
  let values = Dictionary(uniqueKeysWithValues: Gamepad.events(pad).map { ("\($0.type):\($0.code)", $0.value) })
  #expect(values["1:307"] == 1 && values["1:304"] == 0)
  #expect(values["3:0"] == 32767 && values["3:1"] == -32767)
  #expect(values["3:5"] == 128)
  #expect(values["3:17"] == 1)
}
