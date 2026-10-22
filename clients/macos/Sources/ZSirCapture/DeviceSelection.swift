import AppKit
import AVFoundation

struct DeviceSelection: Equatable {
    var cameraID = ""
    var microphoneID = ""
    var displayID: UInt32 = 0
}

struct DeviceOption: Identifiable {
    let id: String
    let name: String
}

@MainActor
func captureDeviceOptions(_ media: AVMediaType) -> [DeviceOption] {
    let types: [AVCaptureDevice.DeviceType] = media == .video
        ? [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        : [.microphone, .external]
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: media, position: .unspecified)
        .devices.map { DeviceOption(id: $0.uniqueID, name: $0.localizedName) }
}
