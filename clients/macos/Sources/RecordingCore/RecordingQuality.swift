import Foundation

public enum RecordingQuality: String, CaseIterable, Identifiable, Sendable {
    case compact, standard, high
    public var id: String { rawValue }
    public var title: String { switch self { case .compact: return "省空间"; case .standard: return "标准"; case .high: return "高画质" } }
    public var cameraBitRate: Int { switch self { case .compact: return 4_000_000; case .standard: return 8_000_000; case .high: return 12_000_000 } }
    public func desktopBitRate(width: Int, height: Int) throws -> Int {
        guard width >= 2, height >= 2, width <= 32768, height <= 32768 else { throw RecordingError("显示器尺寸超出支持范围") }
        let base = Double(cameraBitRate) * 1.5
        let rate = base * max(1, Double(width / 2 * 2) * Double(height / 2 * 2) / 2_073_600)
        guard rate.isFinite, rate <= Double(Int32.max) else { throw RecordingError("目标码率超出编码器支持范围") }
        return Int(rate)
    }
}

public enum RecordingCapabilities {
    public static var macOS12Edition: Bool {
        #if ZSIR_MACOS12_COMPAT
        return true
        #else
        return false
        #endif
    }
    public static var applicationName: String { macOS12Edition ? "庄Sir采访录制助手（macOS12兼容版）" : "庄Sir采访录制助手" }
    public static var systemAudio: Bool {
        if #available(macOS 13, *) { return !macOS12Edition }
        return false
    }
}
