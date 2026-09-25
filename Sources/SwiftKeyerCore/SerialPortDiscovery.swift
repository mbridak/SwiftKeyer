import Foundation
import IOKit
import IOKit.serial

public enum SerialPortDiscovery {
  public static func availablePorts() -> [SerialPortInfo] {
    var portsByPath: [String: SerialPortInfo] = [:]

    for path in iokitCalloutPaths() {
      let name = URL(fileURLWithPath: path).lastPathComponent
      portsByPath[path] = SerialPortInfo(
        path: path,
        name: name,
        description: descriptionForCallout(path)
      )
    }

    for path in deviceCalloutPaths() where portsByPath[path] == nil {
      let name = URL(fileURLWithPath: path).lastPathComponent
      portsByPath[path] = SerialPortInfo(
        path: path,
        name: name,
        description: descriptionForCallout(path)
      )
    }

    return portsByPath.values.sorted {
      $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
  }

  private static func iokitCalloutPaths() -> [String] {
    guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else {
      return []
    }

    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else {
      return []
    }
    defer { IOObjectRelease(iterator) }

    var paths: [String] = []
    while true {
      let service = IOIteratorNext(iterator)
      if service == 0 {
        break
      }
      if let path = stringProperty(service, key: kIOCalloutDeviceKey as String) {
        paths.append(path)
      }
      IOObjectRelease(service)
    }
    return paths
  }

  private static func deviceCalloutPaths() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
    return
      names
      .filter { $0.hasPrefix("cu.") || $0.hasPrefix("tty.") }
      .map { "/dev/\($0)" }
  }

  private static func stringProperty(_ service: io_service_t, key: String) -> String? {
    guard
      let property = IORegistryEntryCreateCFProperty(
        service,
        key as CFString,
        kCFAllocatorDefault,
        0
      )
    else {
      return nil
    }
    return property.takeRetainedValue() as? String
  }

  private static func descriptionForCallout(_ path: String) -> String {
    let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    if let destination, !destination.isEmpty {
      return URL(fileURLWithPath: destination).lastPathComponent
    }
    return "Serial device"
  }
}
