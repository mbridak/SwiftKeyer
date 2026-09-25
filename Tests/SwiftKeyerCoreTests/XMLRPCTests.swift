import XCTest

@testable import SwiftKeyerCore

final class XMLRPCTests: XCTestCase {
  func testDecodesStringMethodCall() throws {
    let xml = """
      <?xml version="1.0"?>
      <methodCall>
        <methodName>k1elsendstring</methodName>
        <params><param><value><string>CQ &amp; test</string></value></param></params>
      </methodCall>
      """
    let call = try XMLRPCRequestDecoder.decode(Data(xml.utf8))

    XCTAssertEqual(call.name, "k1elsendstring")
    XCTAssertEqual(call.parameters, [.string("CQ & test")])
  }

  func testDecodesIntegerMethodCallWithoutParams() throws {
    let xml = "<methodCall><methodName>system.listMethods</methodName></methodCall>"
    let call = try XMLRPCRequestDecoder.decode(Data(xml.utf8))

    XCTAssertEqual(call.name, "system.listMethods")
    XCTAssertTrue(call.parameters.isEmpty)
  }

  func testDecodesTypedValues() throws {
    let xml = """
      <methodCall><methodName>test</methodName><params>
      <param><value><array><data><value><int>7</int></value><value><boolean>1</boolean></value></data></array></value></param>
      </params></methodCall>
      """
    let call = try XMLRPCRequestDecoder.decode(Data(xml.utf8))

    XCTAssertEqual(call.parameters, [.array([.integer(7), .boolean(true)])])
  }

  func testRejectsDoctypeAndEntityDeclarations() {
    let xml = """
      <?xml version="1.0"?>
      <!DOCTYPE methodCall [<!ENTITY value "test">]>
      <methodCall><methodName>test</methodName></methodCall>
      """

    XCTAssertThrowsError(try XMLRPCRequestDecoder.decode(Data(xml.utf8)))
  }

  func testEncodesEscapedResponseAndFault() {
    let response = String(decoding: XMLRPCResponseEncoder.response(.string("A & B")), as: UTF8.self)
    let fault = String(
      decoding: XMLRPCResponseEncoder.fault(code: -1, reason: "bad <call>"), as: UTF8.self)

    XCTAssertTrue(response.contains("<string>A &amp; B</string>"))
    XCTAssertTrue(fault.contains("<int>-1</int>"))
    XCTAssertTrue(fault.contains("bad &lt;call&gt;"))
  }

  func testHTTPDecoderWaitsForCompleteBody() throws {
    let body = Data("<methodCall/>".utf8)
    var request = Data("POST /RPC2 HTTP/1.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
    request.append(Data(body.prefix(4)))

    XCTAssertNil(try XMLRPCHTTPDecoder.decode(request))

    request.append(body.suffix(from: 4))
    let frame = try XCTUnwrap(try XMLRPCHTTPDecoder.decode(request))
    XCTAssertEqual(frame.request.method, "POST")
    XCTAssertEqual(frame.request.path, "/RPC2")
    XCTAssertEqual(frame.request.body, body)
    XCTAssertEqual(frame.consumedBytes, request.count)
  }

  func testHTTPDecoderRejectsNonPost() {
    let request = Data("GET /RPC2 HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
    XCTAssertThrowsError(try XMLRPCHTTPDecoder.decode(request)) { error in
      XCTAssertEqual(error as? XMLRPCHTTPError, .unsupportedMethod)
    }
  }
}
