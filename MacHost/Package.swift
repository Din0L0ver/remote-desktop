// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacHost",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [.package(path: "../RemoteProtocol")],
    targets: [
        .executableTarget(
            name: "MacHost",
            dependencies: ["RemoteProtocol"],
            path: "Sources"
        ),
        .testTarget(name: "MacHostTests", dependencies: ["MacHost", "RemoteProtocol"])
    ]
)
