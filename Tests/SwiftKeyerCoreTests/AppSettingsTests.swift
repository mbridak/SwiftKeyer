import XCTest

@testable import SwiftKeyerCore

final class AppSettingsTests: XCTestCase {
  func testLoadsLegacyPythonSettings() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let json = """
      {"device":"/dev/cu.KeyBoard_AMP","1":"CQ","2":"TEST","mode_register":"10110101"}
      """
    try Data(json.utf8).write(to: url)

    let settings = try SettingsStore(url: url).load()

    XCTAssertEqual(settings.device, "/dev/cu.KeyBoard_AMP")
    XCTAssertEqual(settings.macros, ["CQ", "TEST", "", "", "", ""])
    XCTAssertEqual(settings.paddleSettings.register, 0xB5)
  }

  func testFirstLoadCreatesDefaultSettings() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let store = SettingsStore(url: url)
    let settings = try store.load()

    XCTAssertEqual(settings, KeyerSettings())
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  func testSavesCompatibleKeysAndModeRegister() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let settings = KeyerSettings(
      device: "/dev/cu.usbserial-100",
      macros: ["ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX"]
    )
    try SettingsStore(url: url).save(settings)

    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    XCTAssertEqual(object?["1"] as? String, "ONE")
    XCTAssertEqual(object?["6"] as? String, "SIX")
    XCTAssertEqual(object?["mode_register"] as? String, "11001110")
  }

  func testRejectsInvalidSavedModeRegister() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let json = #"{"device":"/dev/cu.Test","mode_register":"12x10110"}"#
    try Data(json.utf8).write(to: url)

    XCTAssertThrowsError(try SettingsStore(url: url).load()) { error in
      XCTAssertEqual(error as? SettingsStoreError, .invalidRegister)
    }
  }

  private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("WinKeyerSettings-\(UUID().uuidString).json")
  }
}
