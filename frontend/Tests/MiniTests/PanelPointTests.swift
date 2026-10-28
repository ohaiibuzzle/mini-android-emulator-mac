import CoreGraphics
import Foundation
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

/// Screenshots turn the unrotated frame the way the screen shows it, matching panelPoint.
@Test func screenshotsTurnLikeTheScreen() throws {
  // A 2x1 panel: red on the left, green on the right.
  let px: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255]
  let panel = try #require(
    CGImage(
      width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(px) as CFData)!,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent))
  // Top-to-bottom, left-to-right red channels of the turned image.
  func reds(_ r: Rotation) throws -> [UInt8] {
    let img = try #require(ScreenView.turned(panel, r))
    let data = try #require(img.dataProvider?.data) as Data
    return (0..<img.height).flatMap { y in (0..<img.width).map { x in data[y * img.bytesPerRow + x * 4] } }
  }
  #expect(try reds(.portrait) == [255, 0])
  #expect(try reds(.landscape) == [0, 255])  // panel top-right at the displayed top-left
  #expect(try reds(.reverseLandscape) == [255, 0])
  #expect(try reds(.reversePortrait) == [0, 255])
}
