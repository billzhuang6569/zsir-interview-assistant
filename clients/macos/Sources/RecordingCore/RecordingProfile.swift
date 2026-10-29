import Foundation

public enum RecordingProfile: String, CaseIterable, Identifiable, Sendable {
    case balanced, detailed, native

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .balanced: return "均衡 · 1080p"
        case .detailed: return "清晰 · 1440p"
        case .native: return "原始分辨率"
        }
    }

    // Caps the longest edge, including portrait displays. Rounding down keeps
    // encoder dimensions even and never enlarges the source.
    public func dimensions(width: Int, height: Int) throws -> (width: Int, height: Int) {
        guard width >= 2, height >= 2, width <= 32768, height <= 32768 else {
            throw RecordingError("显示器尺寸超出支持范围")
        }
        let limit: Int
        switch self {
        case .balanced: limit = 1920
        case .detailed: limit = 2560
        case .native: limit = max(width, height)
        }
        let scale = min(1, Double(limit) / Double(max(width, height)))
        let outputWidth = max(2, Int(Double(width) * scale) / 2 * 2)
        let outputHeight = max(2, Int(Double(height) * scale) / 2 * 2)
        return (outputWidth, outputHeight)
    }
}
