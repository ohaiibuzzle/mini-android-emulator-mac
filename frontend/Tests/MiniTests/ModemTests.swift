import Foundation
import Testing
@testable import Mini

/// Replies must match the goldfish radio HAL's parsers (hals/radio/AtResponse.cpp); anything else aborts it.
@Test func modemInitSequenceIsAllOK() {
  var m = Modem()
  for cmd in ["ATE0Q0V1", "AT+CMEE=1", "AT+CREG=2", "AT+CGREG=2", "AT+CEREG=2", "AT+CCWA=1", "AT+CMOD=0", "AT+CMUT=0",
              "AT+CSSN=0,1", "AT+COLP=0", "AT+CSCS=\"HEX\"", "AT+CUSD=1", "AT+CGEREP=1,0", "AT+CMGF=0"] {
    #expect(m.reply(to: cmd) == "OK\r", "\(cmd)")
  }
  // CFUN? also brings the registration and signal reports the HAL only gets unsolicited.
  let r = m.reply(to: "AT+CFUN?")
  #expect(r.hasPrefix("+CFUN: 1\rOK\r+CREG: 1,\"0001\",\"00000001\",7\r"))
  #expect(r.contains("+CSQ: 2147483647,2147483647,2147483647,2147483647,2147483647,2147483647,2147483647,28,85,10,200,15\r"))
}

@Test func modemOperatorChainAnswersEachFormat() {
  var m = Modem()
  #expect(m.reply(to: "AT+COPS=3,0;+COPS?;+COPS=3,1;+COPS?;+COPS=3,2;+COPS?")
    == "+COPS: 0,0,Mini Mobile\r+COPS: 0,1,Mini\r+COPS: 0,2,310260\rOK\r")
  #expect(m.reply(to: "AT+COPS?") == "+COPS: 0,2,310260\rOK\r")
}

@Test func modemIdentityDataAndErrors() {
  var m = Modem()
  #expect(m.reply(to: "AT+CGSN=2") == "86740002204719901\rOK\r")
  #expect(m.reply(to: "AT+CPIN?") == "+CPIN: READY\rOK\r")
  #expect(m.reply(to: "AT+CTEC=4,\"20\"") == "+CTEC: DONE\rOK\r")
  #expect(m.reply(to: "AT+CGDCONT=1,\"IPV4V6\",\"fast.t-mobile.com\",,0,0") == "OK\r")
  #expect(m.reply(to: "AT+CGCONTRDP=1") == "+CGCONTRDP: 1,5,\"fast.t-mobile.com\",10.0.2.15/24,10.0.2.2,10.0.2.3\rOK\r")
  #expect(m.reply(to: "AT+CSCA?") == "+CME ERROR: 4\r")
}

@Test func modemReplaysSimProfile() throws {
  let xml = """
    <IccProfile><MF path="3F00"><EF name="EF_ICCID" id="2FE2" structure="transparent">
    <SIMIO cmd="B0" p1="0" p2="0" p3="A" data="">144,0,98683081462002318379</SIMIO></EF></MF></IccProfile>
    """
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("mini-sim-\(UUID()).xml")
  try xml.write(to: url, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: url) }
  var m = Modem(profile: url)
  #expect(m.reply(to: "AT+CRSM=176,12258,0,0,10") == "+CRSM: 144,0,98683081462002318379\rOK\r")
  #expect(m.reply(to: "AT+CRSM=176,12258,0,0,11") == "+CRSM: 106,130\rOK\r")
}
