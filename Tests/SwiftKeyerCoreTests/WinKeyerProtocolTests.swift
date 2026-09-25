import XCTest

@testable import SwiftKeyerCore

final class WinKeyerProtocolTests: XCTestCase {
  func testCommandPackets() {
    XCTAssertEqual(WinKeyerProtocol.hostOpen, Data([0x00, 0x02]))
    XCTAssertEqual(WinKeyerProtocol.hostClose, Data([0x00, 0x03]))
    XCTAssertEqual(WinKeyerProtocol.speedPotRange, Data([0x05, 0x05, 0x32, 0x00]))
    XCTAssertEqual(WinKeyerProtocol.requestSpeedPot, Data([0x07]))
    XCTAssertEqual(WinKeyerProtocol.requestStatus, Data([0x15]))
    XCTAssertEqual(WinKeyerProtocol.setSpeed(20), Data([0x02, 20]))
    XCTAssertEqual(WinKeyerProtocol.setMode(.standard), Data([0x0E, 0xCE]))
    XCTAssertEqual(WinKeyerProtocol.sendText("cq"), Data("CQ".utf8))
    XCTAssertEqual(WinKeyerProtocol.sendBlended("ar"), Data([0x1B]) + Data("AR".utf8))
    XCTAssertEqual(WinKeyerProtocol.tuneOn, Data([0x0B, 0x01]))
    XCTAssertEqual(WinKeyerProtocol.tuneOff, Data([0x0B, 0x00]))
  }

  func testDefaultModeRegisterRoundTrip() {
    XCTAssertEqual(PaddleSettings.standard.register, 0xCE)
    XCTAssertEqual(PaddleSettings(register: 0xCE), .standard)
  }

  func testKeyModesEncodeInRegisterBits() {
    XCTAssertEqual(
      PaddleSettings(
        disablePaddleWatchdog: false,
        paddleEchoBack: false,
        keyMode: .iambicA,
        paddleSwap: false,
        serialEchoBack: false,
        autoSpace: false,
        ctSpacing: false
      ).register,
      0x10
    )
    XCTAssertEqual(
      PaddleSettings(
        disablePaddleWatchdog: false,
        paddleEchoBack: false,
        keyMode: .ultimatic,
        paddleSwap: false,
        serialEchoBack: false,
        autoSpace: false,
        ctSpacing: false
      ).register,
      0x20
    )
    XCTAssertEqual(
      PaddleSettings(
        disablePaddleWatchdog: false,
        paddleEchoBack: false,
        keyMode: .bug,
        paddleSwap: false,
        serialEchoBack: false,
        autoSpace: false,
        ctSpacing: false
      ).register,
      0x30
    )
  }

  func testIncomingByteDecoding() {
    XCTAssertEqual(WinKeyerProtocol.decode(0xC0), .status)
    XCTAssertEqual(WinKeyerProtocol.decode(0xFF), .status)
    XCTAssertEqual(WinKeyerProtocol.decode(0x80), .speedPot(5))
    XCTAssertEqual(WinKeyerProtocol.decode(0xA5), .speedPot(42))
    XCTAssertEqual(WinKeyerProtocol.decode(0x41), .echo("A"))
    XCTAssertEqual(WinKeyerProtocol.decode(0x07), .ignored)
  }

  func testLiveTextDiffAppendsUppercasedSuffix() {
    XCTAssertEqual(
      LiveTextDiff.commands(from: "cq ", to: "cq 73"),
      [Data("73".utf8)]
    )
  }

  func testLiveTextDiffDeletesEveryRemovedByte() {
    XCTAssertEqual(
      LiveTextDiff.commands(from: "TEST", to: "T"),
      [Data([0x08, 0x08, 0x08])]
    )
  }

  func testLiveTextDiffRepairsSameLengthReplacement() {
    XCTAssertEqual(
      LiveTextDiff.commands(from: "CAR", to: "CAT"),
      [Data([0x08]), Data("T".utf8)]
    )
  }

  func testLiveTextDiffIgnoresCaseOnlyChanges() {
    XCTAssertTrue(LiveTextDiff.commands(from: "Test", to: "TEST").isEmpty)
  }
}
