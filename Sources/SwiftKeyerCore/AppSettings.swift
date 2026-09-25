import Foundation

public struct SerialPortInfo: Identifiable, Hashable, Sendable {
  public let path: String
  public let name: String
  public let description: String

  public var id: String { path }

  public init(path: String, name: String, description: String) {
    self.path = path
    self.name = name
    self.description = description
  }
}

public enum KeyerKeyMode: String, CaseIterable, Codable, Identifiable, Sendable {
  case iambicB = "Iambic B"
  case iambicA = "Iambic A"
  case ultimatic = "Ultimatic"
  case bug = "Bug Mode"

  public var id: String { rawValue }

  var bits: UInt8 {
    switch self {
    case .iambicB:
      return 0
    case .iambicA:
      return 1
    case .ultimatic:
      return 2
    case .bug:
      return 3
    }
  }

  init(bits: UInt8) {
    switch bits & 0x03 {
    case 0:
      self = .iambicB
    case 1:
      self = .iambicA
    case 2:
      self = .ultimatic
    default:
      self = .bug
    }
  }
}

public struct PaddleSettings: Codable, Equatable, Sendable {
  public var disablePaddleWatchdog: Bool
  public var paddleEchoBack: Bool
  public var keyMode: KeyerKeyMode
  public var paddleSwap: Bool
  public var serialEchoBack: Bool
  public var autoSpace: Bool
  public var ctSpacing: Bool

  public static let standard = PaddleSettings(
    disablePaddleWatchdog: true,
    paddleEchoBack: true,
    keyMode: .iambicB,
    paddleSwap: true,
    serialEchoBack: true,
    autoSpace: true,
    ctSpacing: false
  )

  public init(
    disablePaddleWatchdog: Bool,
    paddleEchoBack: Bool,
    keyMode: KeyerKeyMode,
    paddleSwap: Bool,
    serialEchoBack: Bool,
    autoSpace: Bool,
    ctSpacing: Bool
  ) {
    self.disablePaddleWatchdog = disablePaddleWatchdog
    self.paddleEchoBack = paddleEchoBack
    self.keyMode = keyMode
    self.paddleSwap = paddleSwap
    self.serialEchoBack = serialEchoBack
    self.autoSpace = autoSpace
    self.ctSpacing = ctSpacing
  }

  public init(register: UInt8) {
    self.init(
      disablePaddleWatchdog: register & 0x80 != 0,
      paddleEchoBack: register & 0x40 != 0,
      keyMode: KeyerKeyMode(bits: (register >> 4) & 0x03),
      paddleSwap: register & 0x08 != 0,
      serialEchoBack: register & 0x04 != 0,
      autoSpace: register & 0x02 != 0,
      ctSpacing: register & 0x01 != 0
    )
  }

  public var register: UInt8 {
    (disablePaddleWatchdog ? 0x80 : 0)
      | (paddleEchoBack ? 0x40 : 0)
      | (keyMode.bits << 4)
      | (paddleSwap ? 0x08 : 0)
      | (serialEchoBack ? 0x04 : 0)
      | (autoSpace ? 0x02 : 0)
      | (ctSpacing ? 0x01 : 0)
  }
}

public struct KeyerSettings: Codable, Equatable, Sendable {
  public var device: String
  public var macros: [String]
  public var paddleSettings: PaddleSettings

  private enum CodingKeys: String, CodingKey {
    case device
    case modeRegister = "mode_register"
    case macro1 = "1"
    case macro2 = "2"
    case macro3 = "3"
    case macro4 = "4"
    case macro5 = "5"
    case macro6 = "6"
  }

  public init(
    device: String = "",
    macros: [String] = Array(repeating: "", count: 6),
    paddleSettings: PaddleSettings = .standard
  ) {
    self.device = device
    self.macros = Self.normalizedMacros(macros)
    self.paddleSettings = paddleSettings
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let macro1 = try container.decodeIfPresent(String.self, forKey: .macro1) ?? ""
    let macro2 = try container.decodeIfPresent(String.self, forKey: .macro2) ?? ""
    let macro3 = try container.decodeIfPresent(String.self, forKey: .macro3) ?? ""
    let macro4 = try container.decodeIfPresent(String.self, forKey: .macro4) ?? ""
    let macro5 = try container.decodeIfPresent(String.self, forKey: .macro5) ?? ""
    let macro6 = try container.decodeIfPresent(String.self, forKey: .macro6) ?? ""
    let savedMacros = [macro1, macro2, macro3, macro4, macro5, macro6]
    let device = try container.decodeIfPresent(String.self, forKey: .device) ?? ""
    let modeRegister =
      try container.decodeIfPresent(String.self, forKey: .modeRegister) ?? "11001110"
    guard modeRegister.count == 8,
      modeRegister.allSatisfy({ $0 == "0" || $0 == "1" }),
      let register = UInt8(modeRegister, radix: 2)
    else {
      throw SettingsStoreError.invalidRegister
    }

    self.init(
      device: device,
      macros: savedMacros,
      paddleSettings: PaddleSettings(register: register)
    )
  }

  public func encode(to encoder: Encoder) throws {
    let normalized = Self.normalizedMacros(macros)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(device, forKey: .device)
    try container.encode(
      String(paddleSettings.register, radix: 2).leftPadded(to: 8, with: "0"), forKey: .modeRegister)
    try container.encode(normalized[0], forKey: .macro1)
    try container.encode(normalized[1], forKey: .macro2)
    try container.encode(normalized[2], forKey: .macro3)
    try container.encode(normalized[3], forKey: .macro4)
    try container.encode(normalized[4], forKey: .macro5)
    try container.encode(normalized[5], forKey: .macro6)
  }

  private static func normalizedMacros(_ values: [String]) -> [String] {
    let count = min(max(values.count, 6), 6)
    return (values + Array(repeating: "", count: 6 - count)).prefix(6).map { $0 }
  }
}

public enum SettingsStoreError: LocalizedError, Equatable {
  case invalidRegister

  public var errorDescription: String? {
    switch self {
    case .invalidRegister:
      return "The saved mode register is invalid."
    }
  }
}

public struct SettingsStore: Sendable {
  public static var defaultURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pywinkeyer.json")
  }

  public let url: URL

  public init(url: URL = SettingsStore.defaultURL) {
    self.url = url
  }

  public func load() throws -> KeyerSettings {
    guard FileManager.default.fileExists(atPath: url.path) else {
      let settings = KeyerSettings()
      try save(settings)
      return settings
    }

    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(KeyerSettings.self, from: data)
  }

  public func save(_ settings: KeyerSettings) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(settings)
    try data.write(to: url, options: .atomic)
  }
}

extension String {
  fileprivate func leftPadded(to length: Int, with character: Character) -> String {
    guard count < length else { return self }
    return String(repeating: String(character), count: length - count) + self
  }
}
