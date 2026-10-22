import RecordingCore
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
    let types: [AVCaptureDevice.DeviceType]
    if #available(macOS 14, *), !RecordingCapabilities.macOS12Edition {
        types = media == .video
            ? [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
            : [.microphone, .external]
    } else if #available(macOS 13, *) {
        types = media == .video
            ? [.builtInWideAngleCamera, .externalUnknown, .deskViewCamera]
            : [.builtInMicrophone, .externalUnknown]
    } else {
        types = media == .video ? [.builtInWideAngleCamera, .externalUnknown] : [.builtInMicrophone, .externalUnknown]
    }
    var seen = Set<String>()
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: media, position: .unspecified)
        .devices.filter { seen.insert($0.uniqueID).inserted }
        .map { DeviceOption(id: $0.uniqueID, name: $0.localizedName) }
}
