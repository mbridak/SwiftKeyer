import Foundation

public indirect enum XMLRPCValue: Equatable, Sendable {
  case none
  case boolean(Bool)
  case integer(Int)
  case double(Double)
  case string(String)
  case array([XMLRPCValue])
  case dictionary([String: XMLRPCValue])
  case data(Data)
  case dateTime(String)

  public var stringValue: String? {
    if case .string(let value) = self {
      return value
    }
    return nil
  }

  public var integerValue: Int? {
    if case .integer(let value) = self {
      return value
    }
    return nil
  }
}

public struct XMLRPCMethodCall: Equatable, Sendable {
  public let name: String
  public let parameters: [XMLRPCValue]

  public init(name: String, parameters: [XMLRPCValue]) {
    self.name = name
    self.parameters = parameters
  }
}

public struct XMLRPCFault: LocalizedError, Equatable, Sendable {
  public let code: Int
  public let reason: String

  public init(code: Int, reason: String) {
    self.code = code
    self.reason = reason
  }

  public var errorDescription: String? { reason }
}

public enum XMLRPCError: LocalizedError, Equatable {
  case emptyRequest
  case malformedXML
  case invalidMethodCall
  case unsupportedValue
  case invalidData
  case requestTooLarge

  public var errorDescription: String? {
    switch self {
    case .emptyRequest:
      return "The XML-RPC request is empty"
    case .malformedXML:
      return "The XML-RPC request is not valid XML"
    case .invalidMethodCall:
      return "The XML-RPC method call is invalid"
    case .unsupportedValue:
      return "The XML-RPC request contains an unsupported value"
    case .invalidData:
      return "The XML-RPC base64 value is invalid"
    case .requestTooLarge:
      return "The XML-RPC request is too large"
    }
  }
}

public enum XMLRPCRequestDecoder {
  public static func decode(_ data: Data) throws -> XMLRPCMethodCall {
    guard !data.isEmpty else {
      throw XMLRPCError.emptyRequest
    }
    guard data.count <= 1_048_576 else {
      throw XMLRPCError.requestTooLarge
    }

    if let prefix = String(data: data.prefix(16_384), encoding: .utf8)?.uppercased(),
      prefix.contains("<!DOCTYPE") || prefix.contains("<!ENTITY")
    {
      throw XMLRPCError.malformedXML
    }

    let delegate = XMLTreeParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    parser.shouldProcessNamespaces = false

    guard parser.parse(), delegate.failure == nil, let root = delegate.root else {
      throw XMLRPCError.malformedXML
    }
    return try methodCall(from: root)
  }

  private static func methodCall(from root: XMLNode) throws -> XMLRPCMethodCall {
    guard root.name == "methodCall" else {
      throw XMLRPCError.invalidMethodCall
    }

    let methodNode = root.children.first { $0.name == "methodName" }
    guard let methodNode else {
      throw XMLRPCError.invalidMethodCall
    }
    let name = methodNode.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      throw XMLRPCError.invalidMethodCall
    }

    let parametersNode = root.children.first { $0.name == "params" }
    let parameters: [XMLRPCValue]
    if let parametersNode {
      parameters = try parametersNode.children
        .filter { $0.name == "param" }
        .map { parameter in
          guard let value = parameter.children.first(where: { $0.name == "value" }) else {
            throw XMLRPCError.invalidMethodCall
          }
          return value.rpcValue
        }
    } else {
      parameters = []
    }

    return XMLRPCMethodCall(name: name, parameters: parameters)
  }
}

public enum XMLRPCResponseEncoder {
  public static func response(_ value: XMLRPCValue) -> Data {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <methodResponse><params><param><value>\(serialize(value))</value></param></params></methodResponse>
      """
    return Data(xml.utf8)
  }

  public static func fault(code: Int, reason: String) -> Data {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <methodResponse><fault><value><struct><member><name>faultCode</name><value><int>\(code)</int></value></member><member><name>faultString</name><value><string>\(escape(reason))</string></value></member></struct></value></fault></methodResponse>
      """
    return Data(xml.utf8)
  }

  private static func serialize(_ value: XMLRPCValue) -> String {
    switch value {
    case .none:
      return "<nil/>"
    case .boolean(let value):
      return "<boolean>\(value ? 1 : 0)</boolean>"
    case .integer(let value):
      return "<int>\(value)</int>"
    case .double(let value):
      return "<double>\(value)</double>"
    case .string(let value):
      return "<string>\(escape(value))</string>"
    case .array(let values):
      return "<array><data>\(values.map(serialize).joined())</data></array>"
    case .dictionary(let values):
      let members = values.keys.sorted().map { key in
        "<member><name>\(escape(key))</name><value>\(serialize(values[key]!))</value></member>"
      }
      return "<struct>\(members.joined())</struct>"
    case .data(let value):
      return "<base64>\(value.base64EncodedString())</base64>"
    case .dateTime(let value):
      return "<dateTime.iso8601>\(escape(value))</dateTime.iso8601>"
    }
  }

  private static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}

private struct XMLNode {
  var name: String
  var text = ""
  var children: [XMLNode] = []
}

private final class XMLTreeParser: NSObject, XMLParserDelegate {
  var failure: Error?
  private(set) var root: XMLNode?
  private var stack: [XMLNode] = []

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    stack.append(XMLNode(name: elementName))
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard !stack.isEmpty else {
      return
    }
    stack[stack.count - 1].text += string
  }

  func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
    guard !stack.isEmpty, let string = String(data: cdataBlock, encoding: .utf8) else {
      return
    }
    stack[stack.count - 1].text += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard !stack.isEmpty else {
      return
    }
    let node = stack.removeLast()
    if stack.isEmpty {
      root = node
    } else {
      stack[stack.count - 1].children.append(node)
    }
  }

  func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
    failure = parseError
  }
}

extension XMLNode {
  fileprivate var descendantValues: [XMLNode] {
    if name == "value" {
      return [self]
    }
    return children.flatMap { $0.descendantValues }
  }

  fileprivate var rpcValue: XMLRPCValue {
    switch name {
    case "nil":
      return .none
    case "boolean":
      return .boolean(text.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    case "int", "i1", "i2", "i4", "i8":
      guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return .string(text)
      }
      return .integer(value)
    case "double":
      guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return .string(text)
      }
      return .double(value)
    case "string":
      return .string(text)
    case "array":
      return .array(children.flatMap { $0.descendantValues.map(\.rpcValue) })
    case "struct":
      var values: [String: XMLRPCValue] = [:]
      for member in children where member.name == "member" {
        guard let name = member.children.first(where: { $0.name == "name" }),
          let value = member.children.first(where: { $0.name == "value" })
        else {
          continue
        }
        values[name.text] = value.rpcValue
      }
      return .dictionary(values)
    case "base64":
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let data = Data(base64Encoded: trimmed) else {
        return .string(trimmed)
      }
      return .data(data)
    case "dateTime.iso8601":
      return .dateTime(text.trimmingCharacters(in: .whitespacesAndNewlines))
    case "value":
      if children.count == 1, let child = children.first {
        return child.rpcValue
      }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? .none : .string(text)
    default:
      return .string(text)
    }
  }
}
