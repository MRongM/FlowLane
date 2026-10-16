// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FlowLane",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppProxyKit", targets: ["AppProxyKit"]),
        // Keep internal module/helper names stable while branding the app product.
        .executable(name: "FlowLane", targets: ["AppProxy"]),
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
