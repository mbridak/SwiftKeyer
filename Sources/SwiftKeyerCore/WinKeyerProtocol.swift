import Foundation

public enum WinKeyerIncomingByte: Equatable, Sendable {
  case status
  case speedPot(Int)
  case echo(Character)
  case ignored
}

public enum WinKeyerProtocol {
  public static let hostOpen = Data([0x00, 0x02])
  public static let hostClose = Data([0x00, 0x03])
  public static let speedPotRange = Data([0x05, 0x05, 0x32, 0x00])
  public static let requestSpeedPot = Data([0x07])
  public static let requestStatus = Data([0x15])
  public static let backspace = Data([0x08])
  public static let clearBuffer = Data([0x0A])
  public static let tuneOn = Data([0x0B, 0x01])
  public static let tuneOff = Data([0x0B, 0x00])

  public static func setSpeed(_ speed: Int) -> Data {
    precondition((1...255).contains(speed))
    return Data([0x02, UInt8(speed)])
  }

  public static func setMode(_ settings: PaddleSettings) -> Data {
    Data([0x0E, settings.register])
  }

  public static func sendText(_ text: String) -> Data {
    Data(text.uppercased().utf8)
  }

  public static func sendBlended(_ text: String) -> Data {
    var data = Data([0x1B])
    data.append(contentsOf: text.uppercased().utf8)
    return data
  }

  public static func decode(_ byte: UInt8) -> WinKeyerIncomingByte {
    if byte & 0xC0 == 0xC0 {
      return .status
    }
    if byte & 0xC0 == 0x80 {
      return .speedPot(Int(byte & 0x3F) + 5)
    }
    if (0x20...0x7E).contains(byte) {
      return .echo(Character(UnicodeScalar(byte)))
    }
    return .ignored
  }
}
