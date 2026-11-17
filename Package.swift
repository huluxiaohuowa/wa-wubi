// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WAWubi",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WubiCore", targets: ["WubiCore"]), .executable(name: "WAWubi", targets: ["WAWubi"])],
    targets: [
        .target(name: "WubiCore", path: "Sources/Core"),
        .executableTarget(name: "WAWubi", dependencies: ["WubiCore"], path: "Sources/Mac"),
        .testTarget(name: "CoreTests", dependencies: ["WubiCore"], path: "Tests/CoreTests"),
    ]
)
