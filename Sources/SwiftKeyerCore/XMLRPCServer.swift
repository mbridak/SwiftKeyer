import Foundation
import Network

public enum XMLRPCServerState: Equatable, Sendable {
  case stopped
  case starting
  case listening
  case failed(String)
}

public enum XMLRPCServerError: LocalizedError {
  case alreadyRunning

  public var errorDescription: String? {
    switch self {
    case .alreadyRunning:
      return "The XML-RPC server is already running"
    }
  }
}

public final class XMLRPCServer: @unchecked Sendable {
  public typealias Handler = @Sendable (String, [XMLRPCValue]) async throws -> XMLRPCValue
  public typealias StateHandler = @Sendable (XMLRPCServerState) -> Void

  private let port: NWEndpoint.Port
  private let handler: Handler
  private let stateHandler: StateHandler
  private let queue = DispatchQueue(label: "com.k6gte.swiftkeyer.xmlrpc")
  private let lock = NSLock()
  private let maximumConnections = 32
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var handlerTasks: [UUID: Task<Void, Never>] = [:]

  public init(
    port: NWEndpoint.Port = 8_000,
    handler: @escaping Handler,
    stateHandler: @escaping StateHandler
  ) {
    self.port = port
    self.handler = handler
    self.stateHandler = stateHandler
  }

  public func start() throws {
    let alreadyRunning = withLock { listener != nil }
    guard !alreadyRunning else {
      throw XMLRPCServerError.alreadyRunning
    }

    stateHandler(.starting)
    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.connectionTimeout = 10
    tcpOptions.enableKeepalive = true
    let parameters = NWParameters(tls: nil, tcp: tcpOptions)
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
    let listener = try NWListener(using: parameters)

    listener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      guard let self, let listener else {
        return
      }
      switch state {
      case .ready:
        if self.withLock({ self.listener === listener }) {
          self.stateHandler(.listening)
        }
      case .failed(let error):
        let isCurrent = self.withLock { () -> Bool in
          guard self.listener === listener else {
            return false
          }
          self.listener = nil
          return true
        }
        if isCurrent {
          self.stateHandler(.failed(error.localizedDescription))
        }
      case .cancelled, .setup, .waiting:
        break
      @unknown default:
        break
      }
    }

    let didStart = withLock { () -> Bool in
      guard self.listener == nil else {
        return false
      }
      self.listener = listener
      return true
    }
    guard didStart else {
      throw XMLRPCServerError.alreadyRunning
    }
    listener.start(queue: queue)
  }

  public func stop() {
    let resources = withLock { () -> (NWListener?, [NWConnection], [Task<Void, Never>]) in
      let listener = self.listener
      let connections = Array(self.connections.values)
      let tasks = Array(self.handlerTasks.values)
      self.listener = nil
      self.connections.removeAll()
      self.handlerTasks.removeAll()
      return (listener, connections, tasks)
    }

    resources.0?.cancel()
    for connection in resources.1 {
      connection.cancel()
    }
    for task in resources.2 {
      task.cancel()
    }
    stateHandler(.stopped)
  }

  private func accept(_ connection: NWConnection) {
    let accepted = withLock { () -> Bool in
      guard connections.count < maximumConnections else {
        return false
      }
      connections[ObjectIdentifier(connection)] = connection
      return true
    }
    guard accepted else {
      connection.cancel()
      return
    }

    connection.stateUpdateHandler = { [weak self, weak connection] state in
      guard let self, let connection else {
        return
      }
      switch state {
      case .ready:
        self.receive(connection: connection, buffer: Data())
      case .failed, .cancelled:
        self.removeConnection(connection)
      case .setup, .preparing, .waiting:
        break
      @unknown default:
        break
      }
    }
    connection.start(queue: queue)
  }

  private func receive(connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self, weak connection] data, _, isComplete, error in
      guard let self, let connection else {
        return
      }

      var accumulated = buffer
      if let data, !data.isEmpty {
        accumulated.append(data)
      }

      do {
        if let frame = try XMLRPCHTTPDecoder.decode(accumulated) {
          self.process(frame.request, on: connection)
          return
        }
      } catch {
        self.send(
          XMLRPCResponseEncoder.fault(code: -32700, reason: error.localizedDescription),
          status: "400 Bad Request",
          on: connection
        )
        return
      }

      if error != nil || isComplete {
        self.removeConnection(connection)
        connection.cancel()
        return
      }
      self.receive(connection: connection, buffer: accumulated)
    }
  }

  private func process(_ request: XMLRPCHTTPRequest, on connection: NWConnection) {
    let call: XMLRPCMethodCall
    do {
      call = try XMLRPCRequestDecoder.decode(request.body)
    } catch {
      send(
        XMLRPCResponseEncoder.fault(code: -32700, reason: error.localizedDescription),
        status: "200 OK",
        on: connection
      )
      return
    }

    let taskID = UUID()
    let task = Task { [weak self, weak connection] in
      guard let self, let connection else {
        return
      }
      defer { self.removeHandlerTask(taskID) }
      do {
        let value = try await self.handler(call.name, call.parameters)
        self.send(XMLRPCResponseEncoder.response(value), status: "200 OK", on: connection)
      } catch let fault as XMLRPCFault {
        self.send(
          XMLRPCResponseEncoder.fault(code: fault.code, reason: fault.reason),
          status: "200 OK",
          on: connection
        )
      } catch {
        self.send(
          XMLRPCResponseEncoder.fault(code: -32603, reason: error.localizedDescription),
          status: "200 OK",
          on: connection
        )
      }
    }

    let shouldTrack = withLock { () -> Bool in
      connections[ObjectIdentifier(connection)] != nil
    }
    if shouldTrack {
      withLock { handlerTasks[taskID] = task }
    } else {
      task.cancel()
    }
  }

  private func send(_ body: Data, status: String, on connection: NWConnection) {
    let header =
      "HTTP/1.1 \(status)\r\nContent-Type: text/xml; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    var response = Data(header.utf8)
    response.append(body)
    connection.send(
      content: response,
      completion: .contentProcessed { [weak self, weak connection] _ in
        guard let connection else {
          return
        }
        self?.removeConnection(connection)
        connection.cancel()
      })
  }

  private func removeConnection(_ connection: NWConnection) {
    _ = withLock {
      connections.removeValue(forKey: ObjectIdentifier(connection))
    }
  }

  private func removeHandlerTask(_ id: UUID) {
    _ = withLock {
      handlerTasks.removeValue(forKey: id)
    }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
