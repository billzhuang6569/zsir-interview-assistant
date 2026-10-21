// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZSirCapture",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ZSirCapture", targets: ["ZSirCapture"])],
    targets: [
        .target(name: "RecordingCore"),
        .executableTarget(name: "ZSirCapture", dependencies: ["RecordingCore"]),
        .executableTarget(name: "CaptureChecks", dependencies: ["RecordingCore"], path: "Checks")
    ]
)
