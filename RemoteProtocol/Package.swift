// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemoteProtocol",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "RemoteProtocol", targets: ["RemoteProtocol"])],
    targets: [
        .target(name: "RemoteProtocol"),
        .testTarget(name: "RemoteProtocolTests", dependencies: ["RemoteProtocol"])
    ]
)
