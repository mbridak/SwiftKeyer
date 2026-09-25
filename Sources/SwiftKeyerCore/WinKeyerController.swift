import Foundation

public enum KeyerConnectionState: Equatable, Sendable {
  case disconnected
  case connecting
  case connected
  case failed(String)
}

public enum KeyerRPCState: Equatable, Sendable {
  case stopped
  case starting
  case listening
  case failed(String)
}

public enum KeyerEvent: Sendable {
  case connection(KeyerConnectionState)
  case rpc(KeyerRPCState)
  case output(String)
  case speed(Int)
  case tuning(Bool)
  case error(String)
}

public actor WinKeyerController {
  public nonisolated let events: AsyncStream<KeyerEvent>

  private let eventContinuation: AsyncStream<KeyerEvent>.Continuation
  private var transport: SerialPort?
  private var pollingTask: Task<Void, Never>?
  private var rpcServer: XMLRPCServer?
  private var connectionID = UUID()
  private var lastWrite = Date.distantPast
  private var paddleSettings: PaddleSettings
  private var lastLiveText = ""
  private var lastLiveRevision = -1
  private var isTuning = false
  private var isShuttingDown = false

  public init(paddleSettings: PaddleSettings = .standard) {
    self.paddleSettings = paddleSettings
    let stream = AsyncStream<KeyerEvent>.makeStream()
    events = stream.stream
    eventContinuation = stream.continuation
  }

  deinit {
    eventContinuation.finish()
  }

  public func startRPCServer() {
    guard rpcServer == nil, !isShuttingDown else {
      return
    }

    let server = XMLRPCServer(
      handler: { [weak self] method, parameters in
        guard let self else {
          throw XMLRPCFault(code: -32603, reason: "The keyer is shutting down")
        }
        return try await self.handleRPC(method: method, parameters: parameters)
      },
      stateHandler: { [weak self] state in
        Task {
          await self?.handleRPCServerState(state)
        }
      }
    )
    rpcServer = server

    do {
      try server.start()
    } catch {
      rpcServer = nil
      eventContinuation.yield(.rpc(.failed(error.localizedDescription)))
    }
  }

  public func connect(to path: String) async {
    guard !Task.isCancelled, !isShuttingDown else {
      return
    }
    let selectedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !selectedPath.isEmpty else {
      closeTransport(sendHostClose: true)
      eventContinuation.yield(.connection(.disconnected))
      return
    }

    let identifier = UUID()
    connectionID = identifier
    closeTransport(sendHostClose: true)
    eventContinuation.yield(.connection(.connecting))

    var openedPort: SerialPort?
    do {
      let port = try SerialPort(path: selectedPath)
      openedPort = port
      transport = port
      try writeToCurrentTransport(WinKeyerProtocol.hostClose)
      try await Task.sleep(for: .seconds(1))
      try requireCurrentTransport(identifier, port)

      try writeToCurrentTransport(WinKeyerProtocol.hostOpen)
      try await Task.sleep(for: .milliseconds(500))
      try requireCurrentTransport(identifier, port)

      let initialResponse = try port.readAvailable()
      process(initialResponse)
      try requireCurrentTransport(identifier, port)
      try writeToCurrentTransport(WinKeyerProtocol.speedPotRange)
      try writeToCurrentTransport(WinKeyerProtocol.requestSpeedPot)
      try writeToCurrentTransport(WinKeyerProtocol.setMode(paddleSettings))
      try requireCurrentTransport(identifier, port)

      eventContinuation.yield(.connection(.connected))
      startPolling(identifier: identifier)
    } catch is CancellationError {
      cleanupConnection(identifier: identifier, port: openedPort)
    } catch {
      if connectionID == identifier {
        failTransport(error)
      } else {
        openedPort?.close()
      }
    }
  }

  public func disconnect() {
    connectionID = UUID()
    closeTransport(sendHostClose: true)
    eventContinuation.yield(.connection(.disconnected))
  }

  public func sendText(_ text: String) {
    writeCommand(WinKeyerProtocol.sendText(text))
  }

  public func sendBlended(_ text: String) {
    writeCommand(WinKeyerProtocol.sendBlended(text))
  }

  public func applyLiveTextChange(to text: String, revision: Int) {
    guard revision > lastLiveRevision else {
      return
    }
    lastLiveRevision = revision
    let previousText = lastLiveText
    lastLiveText = text
    for command in LiveTextDiff.commands(from: previousText, to: text) {
      writeCommand(command)
    }
  }

  public func sendMacro(_ text: String) {
    sendText(text)
  }

  public func setSpeed(_ speed: Int) {
    let validSpeed = min(max(speed, 5), 35)
    eventContinuation.yield(.speed(validSpeed))
    writeCommand(WinKeyerProtocol.setSpeed(validSpeed))
  }

  public func setPaddleSettings(_ settings: PaddleSettings) {
    paddleSettings = settings
    writeCommand(WinKeyerProtocol.setMode(settings))
  }

  public func tune(on: Bool) {
    isTuning = on
    eventContinuation.yield(.tuning(on))
    writeCommand(on ? WinKeyerProtocol.tuneOn : WinKeyerProtocol.tuneOff)
  }

  public func clearBuffer() {
    lastLiveText = ""
    writeCommand(WinKeyerProtocol.clearBuffer)
  }

  public func shutdown() {
    guard !isShuttingDown else {
      return
    }
    isShuttingDown = true
    rpcServer?.stop()
    rpcServer = nil
    connectionID = UUID()
    closeTransport(sendHostClose: true)
    eventContinuation.yield(.connection(.disconnected))
    eventContinuation.finish()
  }

  private func handleRPCServerState(_ state: XMLRPCServerState) {
    guard !isShuttingDown else {
      return
    }
    switch state {
    case .stopped:
      eventContinuation.yield(.rpc(.stopped))
    case .starting:
      eventContinuation.yield(.rpc(.starting))
    case .listening:
      eventContinuation.yield(.rpc(.listening))
    case .failed(let message):
      eventContinuation.yield(.rpc(.failed(message)))
    }
  }

  private func handleRPC(method: String, parameters: [XMLRPCValue]) async throws -> XMLRPCValue {
    switch method {
    case "k1elsendstring":
      sendText(try stringParameter(parameters))
      return .none
    case "setspeed":
      let speed = try integerParameter(parameters)
      guard (1...255).contains(speed) else {
        throw XMLRPCFault(code: -32602, reason: "Speed must be between 1 and 255")
      }
      setSpeed(speed)
      return .none
    case "sendblended":
      sendBlended(try stringParameter(parameters))
      return .none
    case "tuneon":
      try requireNoParameters(parameters)
      tune(on: true)
      return .none
    case "tuneoff":
      try requireNoParameters(parameters)
      tune(on: false)
      return .none
    case "clearbuffer":
      try requireNoParameters(parameters)
      clearBuffer()
      return .none
    case "system.listMethods":
      try requireNoParameters(parameters)
      return .array(Self.rpcMethods.map { .string($0) })
    case "system.methodHelp":
      let name = try stringParameter(parameters)
      guard let help = Self.rpcHelp[name] else {
        throw XMLRPCFault(code: -32601, reason: "Method \(name) is not supported")
      }
      return .string(help)
    case "system.methodSignature":
      let name = try stringParameter(parameters)
      guard Self.rpcMethods.contains(name) else {
        throw XMLRPCFault(code: -32601, reason: "Method \(name) is not supported")
      }
      let parameterType: XMLRPCValue
      if name == "k1elsendstring" || name == "sendblended" {
        parameterType = .string("string")
      } else if name == "setspeed" {
        parameterType = .string("int")
      } else if name == "system.methodHelp" || name == "system.methodSignature" {
        parameterType = .string("string")
      } else {
        parameterType = .none
      }
      return .array([.none, parameterType])
    default:
      throw XMLRPCFault(code: -32601, reason: "Method \(method) is not supported")
    }
  }

  private func startPolling(identifier: UUID) {
    pollingTask?.cancel()
    pollingTask = Task { [weak self] in
      await self?.poll(identifier: identifier)
    }
  }

  private func poll(identifier: UUID) async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .milliseconds(100))
        guard let transport, connectionID == identifier else {
          return
        }
        let data = try transport.readAvailable()
        process(data)
        if Date().timeIntervalSince(lastWrite) >= 60 {
          writeCommand(WinKeyerProtocol.requestStatus)
        }
      } catch is CancellationError {
        return
      } catch {
        if connectionID == identifier {
          failTransport(error)
        }
        return
      }
    }
  }

  private func process(_ data: Data) {
    for byte in data {
      switch WinKeyerProtocol.decode(byte) {
      case .status, .ignored:
        continue
      case .speedPot(let speed):
        setSpeed(speed)
      case .echo(let character):
        eventContinuation.yield(.output(String(character)))
      }
    }
  }

  private func writeCommand(_ data: Data) {
    do {
      try writeToCurrentTransport(data)
    } catch {
      failTransport(error)
    }
  }

  private func writeToCurrentTransport(_ data: Data) throws {
    guard let transport else {
      return
    }
    try transport.write(data)
    lastWrite = Date()
  }

  private func requireCurrentTransport(_ identifier: UUID, _ expected: SerialPort) throws {
    guard !Task.isCancelled, connectionID == identifier, transport === expected else {
      throw CancellationError()
    }
  }

  private func cleanupConnection(identifier: UUID, port: SerialPort?) {
    if connectionID == identifier {
      closeTransport(sendHostClose: true)
    } else {
      port?.close()
    }
  }

  private func closeTransport(sendHostClose: Bool) {
    pollingTask?.cancel()
    pollingTask = nil
    lastLiveText = ""

    if let transport {
      if sendHostClose {
        try? transport.write(WinKeyerProtocol.tuneOff)
        try? transport.write(WinKeyerProtocol.hostClose)
      }
      transport.close()
    }
    transport = nil

    if isTuning {
      isTuning = false
      eventContinuation.yield(.tuning(false))
    }
  }

  private func failTransport(_ error: Error) {
    closeTransport(sendHostClose: true)
    let message = error.localizedDescription
    eventContinuation.yield(.error(message))
    eventContinuation.yield(.connection(.failed(message)))
  }

  private func stringParameter(_ parameters: [XMLRPCValue]) throws -> String {
    guard parameters.count == 1, let value = parameters[0].stringValue else {
      throw XMLRPCFault(code: -32602, reason: "Expected one string parameter")
    }
    return value
  }

  private func integerParameter(_ parameters: [XMLRPCValue]) throws -> Int {
    guard parameters.count == 1, let value = parameters[0].integerValue else {
      throw XMLRPCFault(code: -32602, reason: "Expected one integer parameter")
    }
    return value
  }

  private func requireNoParameters(_ parameters: [XMLRPCValue]) throws {
    guard parameters.isEmpty else {
      throw XMLRPCFault(code: -32602, reason: "This method does not accept parameters")
    }
  }

  private static let rpcMethods = [
    "clearbuffer",
    "k1elsendstring",
    "sendblended",
    "setspeed",
    "system.listMethods",
    "system.methodHelp",
    "system.methodSignature",
    "tuneoff",
    "tuneon",
  ]

  private static let rpcHelp: [String: String] = [
    "clearbuffer": "Clears the WinKeyer sending buffer.",
    "k1elsendstring": "Sends text to the WinKeyer as CW.",
    "sendblended": "Sends text as a blended prosign sequence.",
    "setspeed": "Sets the WinKeyer speed in words per minute.",
    "system.listMethods": "Lists the supported XML-RPC methods.",
    "system.methodHelp": "Returns help for a supported XML-RPC method.",
    "system.methodSignature": "Returns a signature for a supported XML-RPC method.",
    "tuneoff": "Stops manual key-down tuning.",
    "tuneon": "Starts manual key-down tuning.",
  ]
}
