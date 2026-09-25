import Foundation

public struct XMLRPCHTTPRequest: Equatable, Sendable {
  public let method: String
  public let path: String
  public let headers: [String: String]
  public let body: Data

  public init(method: String, path: String, headers: [String: String], body: Data) {
    self.method = method
    self.path = path
    self.headers = headers
    self.body = body
  }
}

public struct XMLRPCHTTPFrame: Equatable, Sendable {
  public let request: XMLRPCHTTPRequest
  public let consumedBytes: Int

  public init(request: XMLRPCHTTPRequest, consumedBytes: Int) {
    self.request = request
    self.consumedBytes = consumedBytes
  }
}

public enum XMLRPCHTTPError: LocalizedError, Equatable {
  case headerTooLarge
  case bodyTooLarge
  case malformedRequest
  case unsupportedMethod
  case unsupportedPath
  case unsupportedTransferEncoding
  case missingContentLength
  case invalidContentLength

  public var errorDescription: String? {
    switch self {
    case .headerTooLarge:
      return "The HTTP headers are too large"
    case .bodyTooLarge:
      return "The HTTP request body is too large"
    case .malformedRequest:
      return "The HTTP request is malformed"
    case .unsupportedMethod:
      return "Only HTTP POST is supported"
    case .unsupportedPath:
      return "The XML-RPC path is not supported"
    case .unsupportedTransferEncoding:
      return "Chunked HTTP requests are not supported"
    case .missingContentLength:
      return "Content-Length is required"
    case .invalidContentLength:
      return "Content-Length is invalid"
    }
  }
}

public enum XMLRPCHTTPDecoder {
  public static func decode(_ data: Data) throws -> XMLRPCHTTPFrame? {
    let bytes = Array(data)
    guard bytes.count <= 1_114_112 else {
      throw XMLRPCHTTPError.bodyTooLarge
    }
    guard let separatorIndex = headerSeparatorIndex(in: bytes) else {
      if bytes.count > 16_384 {
        throw XMLRPCHTTPError.headerTooLarge
      }
      return nil
    }
    guard separatorIndex <= 16_384 else {
      throw XMLRPCHTTPError.headerTooLarge
    }

    let headerData = Data(bytes[0...separatorIndex])
    guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
      throw XMLRPCHTTPError.malformedRequest
    }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      throw XMLRPCHTTPError.malformedRequest
    }
    let requestParts = requestLine.split(whereSeparator: { $0.isWhitespace })
    guard requestParts.count >= 2 else {
      throw XMLRPCHTTPError.malformedRequest
    }

    let method = String(requestParts[0]).uppercased()
    guard method == "POST" else {
      throw XMLRPCHTTPError.unsupportedMethod
    }

    let path = String(requestParts[1]).components(separatedBy: "?").first ?? ""
    guard path == "/RPC2" || path == "/" else {
      throw XMLRPCHTTPError.unsupportedPath
    }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else {
        throw XMLRPCHTTPError.malformedRequest
      }
      let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
      headers[name] = value
    }

    if headers["transfer-encoding"] != nil {
      throw XMLRPCHTTPError.unsupportedTransferEncoding
    }
    guard let contentLengthValue = headers["content-length"] else {
      throw XMLRPCHTTPError.missingContentLength
    }
    guard let contentLength = Int(contentLengthValue), contentLength >= 0 else {
      throw XMLRPCHTTPError.invalidContentLength
    }
    guard contentLength <= 1_048_576 else {
      throw XMLRPCHTTPError.bodyTooLarge
    }

    let bodyStart = separatorIndex + 4
    guard data.count >= bodyStart + contentLength else {
      return nil
    }

    let body = Data(bytes[bodyStart..<(bodyStart + contentLength)])
    return XMLRPCHTTPFrame(
      request: XMLRPCHTTPRequest(
        method: method,
        path: path,
        headers: headers,
        body: body
      ),
      consumedBytes: bodyStart + contentLength
    )
  }

  private static func headerSeparatorIndex(in bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else {
      return nil
    }
    for index in 0...(bytes.count - 4)
    where bytes[index] == 13
      && bytes[index + 1] == 10
      && bytes[index + 2] == 13
      && bytes[index + 3] == 10
    {
      return index
    }
    return nil
  }
}
