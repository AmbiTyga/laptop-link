// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "laptop-link",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "link-server", targets: ["LinkServerApp"]),
        .executable(name: "link-client", targets: ["LinkClientApp"])
    ],
    targets: [
        .target(name: "SwiftTerm", path: "Vendor/SwiftTerm/Sources", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "SwiftProtobuf", path: "Vendor/SwiftProtobuf/Sources"),
        .target(name: "LinkProtocol", dependencies: ["SwiftProtobuf"]),
        .target(name: "ProcessSupport"),
        .target(name: "LinkServerKit", dependencies: ["LinkProtocol", "ProcessSupport"]),
        .target(name: "LinkBluetooth", dependencies: ["LinkProtocol"]),
        .executableTarget(name: "LinkServerApp", dependencies: ["LinkServerKit", "LinkBluetooth", "SwiftTerm"]),
        .executableTarget(name: "LinkClientApp", dependencies: ["LinkBluetooth"]),
        .testTarget(name: "LaptopLinkTests", dependencies: ["LinkServerKit", "LinkBluetooth"])
    ]
)
