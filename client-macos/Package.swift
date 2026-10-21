// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZsirRecorder",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Recorder", targets: ["Recorder"]),
        .executable(name: "App", targets: ["App"]),
        .library(name: "Shared", targets: ["Shared"])
    ],
    targets: [
        .target(name: "Shared", path: "Shared"),
        .executableTarget(name: "Recorder", dependencies: ["Shared"], path: "Recorder"),
        .executableTarget(name: "App", dependencies: ["Shared"], path: "App")
    ]
)
