import Foundation
import Testing
@testable import Mini

@Test func sha1MatchesKnownVector() throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("mini-sha1-test")
  try Data("abc".utf8).write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  #expect(try SDKDownload.sha1(of: url) == "a9993e364706816aba3e25717850c26c9cd0d89d")
}
