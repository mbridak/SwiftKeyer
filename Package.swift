// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SwiftKeyer",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "SwiftKeyer", targets: ["SwiftKeyerApp"])
  ],
  targets: [
    .target(name: "CSerialShim"),
    .target(
      name: "SwiftKeyerCore",
      dependencies: ["CSerialShim"]
    ),
    .executableTarget(
      name: "SwiftKeyerApp",
      dependencies: ["SwiftKeyerCore"]
    ),
    .testTarget(
      name: "SwiftKeyerCoreTests",
      dependencies: ["SwiftKeyerCore"]
    ),
  ],
  swiftLanguageModes: [.v5]
)
