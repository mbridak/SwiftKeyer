import Foundation

public enum LiveTextDiff {
  public static func commands(from oldText: String, to newText: String) -> [Data] {
    let oldBytes = Array(oldText.uppercased().utf8)
    let newBytes = Array(newText.uppercased().utf8)
    var sharedPrefix = 0

    while sharedPrefix < oldBytes.count,
      sharedPrefix < newBytes.count,
      oldBytes[sharedPrefix] == newBytes[sharedPrefix]
    {
      sharedPrefix += 1
    }

    var commands: [Data] = []
    let deletedCount = oldBytes.count - sharedPrefix
    if deletedCount > 0 {
      commands.append(Data(repeating: 0x08, count: deletedCount))
    }
    if sharedPrefix < newBytes.count {
      commands.append(Data(newBytes[sharedPrefix...]))
    }
    return commands
  }
}
