// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NetSwitch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "net-switch", targets: ["NetSwitch"])],
    targets: [
        .target(name: "NetSwitchCore"),
        .executableTarget(name: "NetSwitch", dependencies: ["NetSwitchCore"]),
        .testTarget(name: "NetSwitchCoreTests", dependencies: ["NetSwitchCore"])
    ]
)
