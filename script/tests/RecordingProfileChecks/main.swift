import Foundation

// The production error lives in AVFoundation MovieWriter.swift. This Linux-only
// fixture allows the real pure profile/quality files to compile without Apple SDKs.
public struct RecordingError: Error {
    let message: String
    public init(_ message: String) { self.message = message }
}
func check(_ result: Bool, _ message: String) {
    precondition(result, message)
}
for input in [(3840, 2160), (2160, 3840), (5120, 1440), (1365, 767), (2, 2)] {
    for profile in RecordingProfile.allCases {
        let size = try profile.dimensions(width: input.0, height: input.1)
        check(size.width % 2 == 0 && size.height % 2 == 0, "even dimensions")
        check(size.width <= input.0 && size.height <= input.1, "never upscale")
        let cap = profile == .balanced ? 1920 : profile == .detailed ? 2560 : 32768
        check(max(size.width, size.height) <= cap, "longest edge cap")
    }
}
let balanced = try RecordingProfile.balanced.dimensions(width: 3840, height: 2160)
check(balanced.width == 1920 && balanced.height == 1080, "balanced 4K")
let detailed = try RecordingProfile.detailed.dimensions(width: 3840, height: 2160)
check(detailed.width == 2560 && detailed.height == 1440, "detailed 4K")
let native = try RecordingProfile.native.dimensions(width: 1365, height: 767)
check(native.width == 1364 && native.height == 766, "native odd pixels")
let standardRate = try RecordingQuality.standard.desktopBitRate(width: 1920, height: 1080)
check(standardRate == 12_000_000, "baseline bitrate")
let highRate = try RecordingQuality.high.desktopBitRate(width: 3840, height: 2160)
check(highRate == 72_000_000, "4K bitrate")
for input in [(0, 100), (100, 1), (32769, 100)] {
    do {
        _ = try RecordingProfile.balanced.dimensions(width: input.0, height: input.1)
        preconditionFailure("invalid dimensions accepted")
    } catch {}
}
do {
    _ = try RecordingQuality.high.desktopBitRate(width: 32768, height: 32768)
    preconditionFailure("overflowing bitrate accepted")
} catch {}
print("PASS: actual Swift profile/quality landscape, portrait, ultrawide, even pixels, bitrate and invalid inputs (Linux error fixture)")
