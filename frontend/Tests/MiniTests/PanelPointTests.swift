import CoreGraphics
import Testing

@testable import Mini

/// Touch mapping from the displayed (rotated) frame back to the portrait 1080x2400 panel.
@Test func panelPointUndoesRotation() {
  let portrait = CGSize(width: 1080, height: 2400), landscape = CGSize(width: 2400, height: 1080)
  // Portrait: straight scale.
  #expect(ScreenView.panelPoint(u: 0.25, v: 0.5, displayed: portrait, rotation: .portrait) == CGPoint(x: 270, y: 1200))
  // Landscape (panel top on the left): displayed top-left is the panel's top-right, bottom-left its top-left.
  #expect(ScreenView.panelPoint(u: 0, v: 0, displayed: landscape, rotation: .landscape) == CGPoint(x: 1080, y: 0))
  #expect(ScreenView.panelPoint(u: 0, v: 1, displayed: landscape, rotation: .landscape) == CGPoint(x: 0, y: 0))
  #expect(ScreenView.panelPoint(u: 1, v: 1, displayed: landscape, rotation: .landscape) == CGPoint(x: 0, y: 2400))
  // Reverse landscape (panel top on the right): displayed top-right is the panel's top-left.
  #expect(ScreenView.panelPoint(u: 1, v: 0, displayed: landscape, rotation: .reverseLandscape) == CGPoint(x: 0, y: 0))
  // Reverse portrait: point-mirrored.
  #expect(ScreenView.panelPoint(u: 0, v: 0, displayed: portrait, rotation: .reversePortrait) == CGPoint(x: 1080, y: 2400))
}
