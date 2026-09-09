// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LocalVoiceRelay",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalVoiceRelay", targets: ["LocalVoiceRelay"])],
    targets: [
        .target(name: "RelayCore"),
        .executableTarget(name: "LocalVoiceRelay", dependencies: ["RelayCore"]),
        .testTarget(name: "RelayCoreTests", dependencies: ["RelayCore"]),
        .testTarget(name: "NativeTests", dependencies: ["LocalVoiceRelay"])
    ]
)
