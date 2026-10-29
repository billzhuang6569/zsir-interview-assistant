import Foundation

/// Integer frame indices are the authority; nanoseconds are only a clock adapter.
public enum RecordingTimeline {
    public static let framesPerSecond: Int64 = 30

    /// floor(frame * 1e9 / 30), without cumulative rounding or unchecked overflow.
    public static func nanoseconds(forFrame frame: Int64) -> Int64? {
        guard frame >= 0 else { return nil }
        let (whole, overflow) = (frame / framesPerSecond).multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let fraction = (frame % framesPerSecond) * 1_000_000_000 / framesPerSecond
        let (result, additionOverflow) = whole.addingReportingOverflow(fraction)
        return additionOverflow ? nil : result
    }

    /// Last tick at or before the elapsed time. Does not synthesize a startup frame.
    public static func frame(atNanoseconds elapsed: Int64) -> Int64? {
        guard elapsed >= 0 else { return nil }
        return (elapsed / 1_000_000_000) * framesPerSecond
            + (elapsed % 1_000_000_000) * framesPerSecond / 1_000_000_000
    }
}

/// A fixed allocation ring. The owner must serialize every access; this type is not thread safe.
/// A full queue rejects the incoming item so an encoder cannot silently lose an older item.
public struct BoundedRecordingQueue<Element> {
    private var storage: [Element?]
    private var head = 0
    public private(set) var count = 0
    public private(set) var highWaterMark = 0
    public private(set) var rejectedCount: UInt64 = 0
    public var capacity: Int { storage.count }

    public init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    @discardableResult public mutating func enqueue(_ item: Element) -> Bool {
        guard count < capacity else {
            rejectedCount += 1
            return false
        }
        storage[(head + count) % capacity] = item
        count += 1
        highWaterMark = max(highWaterMark, count)
        return true
    }

    public mutating func dequeue() -> Element? {
        guard count > 0 else { return nil }
        let item = storage[head]
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
        return item
    }
}

/// Per-track, per-Take snapshot. Mutate only on the track owner queue; publish copies.
/// Repeating the held image increments repeatedFrames, never capturedFrames.
public struct RecordingDiagnostics: Codable, Equatable, Sendable {
    public var capturedFrames: UInt64 = 0
    public var scheduledFrames: UInt64 = 0
    public var writtenFrames: UInt64 = 0
    public var repeatedFrames: UInt64 = 0
    public var lateFrames: UInt64 = 0
    public var backpressureFrames: UInt64 = 0
    public var previewDroppedFrames: UInt64 = 0
    public var queueDepth: Int = 0
    public var queueHighWaterMark: Int = 0
    public init() {}
}
