import Foundation

/// A minimal AT modem for the goldfish radio HAL (device/generic/goldfish/hals/radio): a ready SIM, registered on
/// LTE with full signal, and mobile data on the guest's eth0 (slirp). No calls or SMS. The HAL aborts on any line it
/// can't parse, so every reply here matches a parser in its AtResponse.cpp; lines end in a bare CR as it expects.
struct Modem {
  static let mccMnc = "310260"
  static let iccid = "89860318640220133897"
  static let imsi = "310260000000000"
  static let imeiSvn = "86740002204719901"

  /// SIM file replies keyed "<file id>:<cmd>:<p1>:<p2>:<p3>" in hex, as in the emulator's iccprofile_for_sim0.xml.
  var simFiles: [String: String] = [:]
  var copsFormat = 2
  var radioOn = true
  var apns: [Int: String] = [:]

  init(profile: URL? = nil) {
    if let profile, let parser = XMLParser(contentsOf: profile) {
      let reader = SimProfileReader()
      parser.delegate = reader
      parser.parse()
      simFiles = reader.files
    }
  }

  /// Answers the radio HAL on QEMU's modem port until QEMU goes away.
  static func run(socket: String, profile: URL) async throws {
    var modem = Modem(profile: FileManager.default.fileExists(atPath: profile.path) ? profile : nil)
    let link = try await Qemu.connect(socket)
    var line = ""
    for try await byte in link.bytes {
      switch byte {
      case 0x0D:
        if !line.isEmpty { try link.write(contentsOf: Data(modem.reply(to: line).utf8)) }
        line = ""
      case 0x0A: break
      default: line.append(Character(UnicodeScalar(byte)))
      }
    }
  }

  /// The reply to one request line (without its CR), unsolicited reports included.
  mutating func reply(to line: String) -> String {
    let body = line.hasPrefix("AT") || line.hasPrefix("at") ? String(line.dropFirst(2)) : line
    // getOperator chains "+COPS=3,0;+COPS?;...": each part answers in turn and one OK ends the lot.
    var out = ""
    for cmd in body.split(separator: ";").map(String.init) {
      switch answer(cmd) {
      case .lines(let l): out += l.map { $0 + "\r" }.joined()
      case .error(let e): return out + "+CME ERROR: \(e)\r"
      }
    }
    return out + "OK\r" + unsolicited(after: body)
  }

  private enum Answer { case lines([String]), error(Int) }

  private mutating func answer(_ cmd: String) -> Answer {
    let operatorNames = ["Mini Mobile", "Mini", Self.mccMnc]
    let cellLoc = "\"0001\",\"00000001\",7"  // LAC, cell id, E-UTRAN
    switch cmd {
    case "+CFUN?": return .lines(["+CFUN: \(radioOn ? 1 : 0)"])
    case "+CFUN=0": radioOn = false; return .lines([])
    case "+CFUN=1": radioOn = true; return .lines([])
    case "+CPIN?": return .lines(["+CPIN: READY"])
    case "+CICCID": return .lines([Self.iccid])
    case "+CIMI": return .lines([Self.imsi])
    case "+CGSN=2": return .lines([Self.imeiSvn])
    case "+CTEC=?": return .lines(["+CTEC: 0,1,5"])  // GSM, WCDMA, LTE
    case "+CTEC?": return .lines(["+CTEC: 32"])  // a bitmask of ModemTechnology: 1 << LTE
    case "+WRMP?": return .lines(["+WRMP: 0"])
    case "+CCSS?": return .lines(["+CCSS: 0"])
    case "+CUSATD?": return .lines(["+CUSATD: 0,1"])
    case "+CREG?", "+CGREG?", "+CEREG?":
      return .lines(["\(cmd.dropLast()): 2,\(radioOn ? 1 : 0),\(cellLoc)"])
    case "+COPS?": return .lines(["+COPS: 0,\(copsFormat),\(operatorNames[copsFormat])"])
    case "+COPS=?": return .lines(["+COPS: (2,\(operatorNames.joined(separator: ",")))"])
    case "+CLCC": return .lines([])
    default: break
    }
    if cmd.hasPrefix("+COPS=3,"), let f = Int(cmd.dropFirst(8)), (0...2).contains(f) { copsFormat = f; return .lines([]) }
    if cmd.hasPrefix("+CTEC=") { return .lines(["+CTEC: DONE"]) }
    if cmd.hasPrefix("+CLCK=") { return .lines(["+CLCK: 0"]) }
    if cmd.hasPrefix("+CRSM=") { return .lines(["+CRSM: " + sim(cmd.dropFirst(6))]) }
    if cmd.hasPrefix("+CGDCONT="), let cid = Int(cmd.dropFirst(9).prefix { $0 != "," }) {
      apns[cid] = cmd.split(separator: ",").dropFirst(2).first.map { String($0).trimmingCharacters(in: ["\""]) } ?? ""
      return .lines([])
    }
    if cmd.hasPrefix("+CGCONTRDP="), let cid = Int(cmd.dropFirst(11)) {
      // slirp's addresses: the guest is 10.0.2.15, the gateway 10.0.2.2, DNS 10.0.2.3.
      return .lines(["+CGCONTRDP: \(cid),5,\"\(apns[cid] ?? "")\",10.0.2.15/24,10.0.2.2,10.0.2.3"])
    }
    // Settings the init sequence makes, and calls the HAL fires without waiting for an answer.
    if cmd.hasPrefix("E0") || cmd.hasPrefix("+CMEE=") || cmd.hasPrefix("+CREG=") || cmd.hasPrefix("+CGREG=")
      || cmd.hasPrefix("+CEREG=") || cmd.hasPrefix("+CCWA=") || cmd.hasPrefix("+CMOD=") || cmd.hasPrefix("+CMUT=")
      || cmd.hasPrefix("+CSSN=") || cmd.hasPrefix("+COLP=") || cmd.hasPrefix("+CSCS=") || cmd.hasPrefix("+CUSD")
      || cmd.hasPrefix("+CGEREP=") || cmd.hasPrefix("+CMGF=") || cmd.hasPrefix("+COPS=") || cmd.hasPrefix("+CHLD")
      || cmd.hasPrefix("+VTS=") || cmd == "A" || cmd == "H" {
      return .lines([])
    }
    return .error(4)  // operation not supported; every other request the HAL makes accepts a CME error
  }

  /// +CRSM=<command>,<file id>,<p1>,<p2>,<p3>[,<data>,<path>], all decimal.
  private func sim(_ args: Substring) -> String {
    let a = args.split(separator: ",", omittingEmptySubsequences: false).prefix(5).compactMap { Int($0) }
    guard a.count == 5 else { return "106,128" }  // 6A80: incorrect parameters
    if a[0] == 214 || a[0] == 220 { return "144,0" }  // UPDATE BINARY / RECORD: accepted, not kept
    let key = [a[1], a[0], a[2], a[3], a[4]].map { String($0, radix: 16, uppercase: true) }.joined(separator: ":")
    return simFiles[key] ?? "106,130"  // 6A82: file not found
  }

  /// Registration and signal reports the HAL only learns from unsolicited lines: after power-on (and the init's
  /// CFUN? query) it gets home registration on LTE and strong signal.
  private func unsolicited(after body: String) -> String {
    guard radioOn, body == "+CFUN?" || body == "+CFUN=1" else { return "" }
    let u = Int32.max  // AtResponse::CSQ::kUnknown
    // gsm ss, ber; cdma dbm, ecio; evdo dbm, ecio, snr; lte ss (asu), rsrp (-dBm), rsrq, rssnr (0.1 dB), cqi
    let csq = [u, u, u, u, u, u, u, 28, 85, 10, 200, 15].map(String.init).joined(separator: ",")
    let loc = "\"0001\",\"00000001\",7"
    return "+CREG: 1,\(loc)\r+CGREG: 1,\(loc)\r+CEREG: 1,\(loc)\r+CTEC: 32\r+CSQ: \(csq)\r"
  }
}

private final class SimProfileReader: NSObject, XMLParserDelegate {
  var files: [String: String] = [:]
  private var fileId = ""
  private var key: String?
  private var text = ""

  func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
              attributes: [String: String] = [:]) {
    if name == "EF" { fileId = attributes["id"] ?? "" }
    guard name == "SIMIO", let cmd = attributes["cmd"], let p1 = attributes["p1"], let p2 = attributes["p2"],
      let p3 = attributes["p3"] else { return }
    // Normalised like Modem.sim's keys: hex without leading zeros.
    let hex = [fileId, cmd, p1, p2, p3].map { Int($0, radix: 16).map { String($0, radix: 16, uppercase: true) } ?? $0 }
    key = hex.joined(separator: ":")
    text = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { if key != nil { text += string } }

  func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
    guard name == "SIMIO", let k = key else { return }
    // shortcut: an EF id under two DFs keeps its first reply; key on the path too if a guest reads both.
    if files[k] == nil { files[k] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    key = nil
  }
}
