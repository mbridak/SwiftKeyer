import CSerialShim
import Darwin
import Foundation

public enum SerialPortError: LocalizedError, Equatable {
  case open(path: String, code: Int32)
  case configure(code: Int32)
  case io(operation: String, code: Int32)
  case timeout(operation: String)
  case disconnected
  case closed

  public var errorDescription: String? {
    switch self {
    case .open(let path, let code):
      return "Unable to open \(path): \(String(cString: strerror(code)))"
    case .configure(let code):
      return "Unable to configure serial port: \(String(cString: strerror(code)))"
    case .io(let operation, let code):
      return "Serial \(operation) failed: \(String(cString: strerror(code)))"
    case .timeout(let operation):
      return "Serial \(operation) timed out"
    case .disconnected:
      return "The WinKeyer disconnected"
    case .closed:
      return "The serial port is closed"
    }
  }
}

public final class SerialPort {
  private var descriptor: Int32 = -1
  private let writeTimeoutMilliseconds: Int

  public init(path: String, writeTimeoutMilliseconds: Int = 1_000) throws {
    self.writeTimeoutMilliseconds = writeTimeoutMilliseconds

    var openedDescriptor: Int32
    repeat {
      openedDescriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
    } while openedDescriptor < 0 && errno == EINTR

    guard openedDescriptor >= 0 else {
      throw SerialPortError.open(path: path, code: errno)
    }

    do {
      try configure(descriptor: openedDescriptor)
      descriptor = openedDescriptor
      try setHandshakeLines()
      try flushInput()
    } catch {
      Darwin.close(openedDescriptor)
      throw error
    }
  }

  deinit {
    close()
  }

  public func readAvailable() throws -> Data {
    let descriptor = try requireOpen()
    let available = serial_bytes_available(descriptor)

    guard available >= 0 else {
      throw SerialPortError.io(operation: "read", code: errno)
    }
    guard available > 0 else {
      return Data()
    }

    var buffer = [UInt8](repeating: 0, count: min(Int(available), 4_096))
    var count: Int
    repeat {
      count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
    } while count < 0 && errno == EINTR

    if count > 0 {
      return Data(buffer[0..<count])
    }
    if count == 0 {
      throw SerialPortError.disconnected
    }

    let code = errno
    if code == EAGAIN || code == EWOULDBLOCK {
      return Data()
    }
    if code == EIO || code == ENXIO || code == ENODEV {
      throw SerialPortError.disconnected
    }
    throw SerialPortError.io(operation: "read", code: code)
  }

  public func write(_ data: Data) throws {
    guard !data.isEmpty else {
      return
    }

    let descriptor = try requireOpen()
    let bytes = Array(data)
    let startedAt = DispatchTime.now().uptimeNanoseconds

    try bytes.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        return
      }

      var offset = 0
      while offset < buffer.count {
        let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        let remaining = writeTimeoutMilliseconds - Int(elapsed)
        guard remaining > 0 else {
          throw SerialPortError.timeout(operation: "write")
        }

        let ready = serial_wait_ready(descriptor, 1, Int32(remaining))
        if ready == 0 {
          throw SerialPortError.timeout(operation: "write")
        }
        if ready < 0 {
          throw SerialPortError.io(operation: "write", code: errno)
        }

        let count = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          buffer.count - offset
        )
        if count > 0 {
          offset += count
          continue
        }
        if count == 0 {
          throw SerialPortError.disconnected
        }

        let code = errno
        if code == EAGAIN || code == EWOULDBLOCK || code == EINTR {
          continue
        }
        if code == EPIPE || code == EIO || code == ENXIO || code == ENODEV {
          throw SerialPortError.disconnected
        }
        throw SerialPortError.io(operation: "write", code: code)
      }
    }
  }

  public func close() {
    guard descriptor >= 0 else {
      return
    }
    Darwin.close(descriptor)
    descriptor = -1
  }

  private func requireOpen() throws -> Int32 {
    guard descriptor >= 0 else {
      throw SerialPortError.closed
    }
    return descriptor
  }

  private func configure(descriptor: Int32) throws {
    var attributes = termios()
    var result: Int32

    repeat {
      result = tcgetattr(descriptor, &attributes)
    } while result < 0 && errno == EINTR

    guard result == 0 else {
      throw SerialPortError.configure(code: errno)
    }

    cfmakeraw(&attributes)
    attributes.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CRTSCTS)
    attributes.c_cflag |= tcflag_t(CS8 | CREAD | CLOCAL | CSTOPB)
    attributes.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)

    guard cfsetispeed(&attributes, speed_t(B1200)) == 0,
      cfsetospeed(&attributes, speed_t(B1200)) == 0
    else {
      throw SerialPortError.configure(code: errno)
    }

    withUnsafeMutableBytes(of: &attributes.c_cc) { bytes in
      bytes[Int(VMIN)] = 0
      bytes[Int(VTIME)] = 0
    }

    repeat {
      result = tcsetattr(descriptor, TCSANOW, &attributes)
    } while result < 0 && errno == EINTR

    guard result == 0 else {
      throw SerialPortError.configure(code: errno)
    }
  }

  private func setHandshakeLines() throws {
    let descriptor = try requireOpen()
    var lines: Int32 = 0
    var result: Int32

    repeat {
      result = ioctl(descriptor, TIOCMGET, &lines)
    } while result < 0 && errno == EINTR

    if result < 0 {
      let code = errno
      if code == ENOTTY || code == EINVAL {
        return
      }
      throw SerialPortError.io(operation: "modem control", code: code)
    }

    lines |= TIOCM_DTR | TIOCM_RTS
    repeat {
      result = ioctl(descriptor, TIOCMBIS, &lines)
    } while result < 0 && errno == EINTR

    if result < 0 {
      let code = errno
      if code == ENOTTY || code == EINVAL {
        return
      }
      throw SerialPortError.io(operation: "modem control", code: code)
    }
  }

  private func flushInput() throws {
    let descriptor = try requireOpen()
    var result: Int32
    repeat {
      result = tcflush(descriptor, TCIFLUSH)
    } while result < 0 && errno == EINTR
    guard result == 0 else {
      throw SerialPortError.io(operation: "flush", code: errno)
    }
  }
}
