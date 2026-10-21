// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZsirRecorder",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Recorder", targets: ["Recorder"]),
        .executable(name: "recorder", targets: ["Recorder"]),
        .executable(name: "App", targets: ["App"]),
        .library(name: "Shared", targets: ["Shared"])
    ],
    targets: [
        .target(name: "Shared", path: "Shared"),
        .executableTarget(name: "Recorder", dependencies: ["Shared"], path: "Recorder",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "RecorderInfo.plist"])]),
        .executableTarget(name: "App", dependencies: ["Shared"], path: "App")
    ]
)
