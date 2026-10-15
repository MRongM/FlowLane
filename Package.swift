// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppProxy",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppProxyKit", targets: ["AppProxyKit"]),
        .executable(name: "AppProxy", targets: ["AppProxy"]),
        .executable(name: "AppProxyHelper", targets: ["AppProxyHelper"])
    ],
    targets: [
        .target(name: "AppProxyKit", resources: [.process("Resources")]),
        .executableTarget(name: "AppProxy", dependencies: ["AppProxyKit"]),
        .executableTarget(name: "AppProxyHelper", dependencies: ["AppProxyKit"]),
        .testTarget(name: "AppProxyKitTests", dependencies: ["AppProxyKit"]),
        .testTarget(name: "AppProxyUITests", dependencies: ["AppProxy", "AppProxyKit"])
    ]
)
