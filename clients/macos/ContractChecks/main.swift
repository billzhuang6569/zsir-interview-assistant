import Foundation

// Standalone: swiftc Sources/RecordingCore/RecordingContract.swift ContractChecks/main.swift -o /tmp/zsir-contract-checks
func check(_ value: @autoclosure () -> Bool) { precondition(value()) }
check(RecordingTimeline.nanoseconds(forFrame: 0) == 0)
check(RecordingTimeline.nanoseconds(forFrame: 1) == 33_333_333)
check(RecordingTimeline.nanoseconds(forFrame: 3) == 100_000_000)
check(RecordingTimeline.nanoseconds(forFrame: 30 * 60 * 60 * 24) == 86_400_000_000_000)
check(RecordingTimeline.nanoseconds(forFrame: -1) == nil)
check(RecordingTimeline.nanoseconds(forFrame: Int64.max) == nil)
check(RecordingTimeline.frame(atNanoseconds: -1) == nil)
check(RecordingTimeline.frame(atNanoseconds: Int64.max) != nil)
check(RecordingTimeline.frame(atNanoseconds: 999_999_999) == 29)
check(RecordingTimeline.frame(atNanoseconds: 1_000_000_000) == 30)
var queue = BoundedRecordingQueue<Int>(capacity: 2)
check(queue.enqueue(1)); check(queue.enqueue(2)); check(!queue.enqueue(3))
check(queue.highWaterMark == 2 && queue.rejectedCount == 1)
check(queue.dequeue() == 1); check(queue.enqueue(4))
check(queue.dequeue() == 2); check(queue.dequeue() == 4); check(queue.dequeue() == nil)
var diagnostics = RecordingDiagnostics()
diagnostics.capturedFrames = 1; diagnostics.repeatedFrames = 29; diagnostics.writtenFrames = 30
let encoded = try JSONEncoder().encode(diagnostics)
let decoded = try JSONDecoder().decode(RecordingDiagnostics.self, from: encoded)
check(decoded == diagnostics)
print("PASS: rational timeline boundaries, overflow, bounded ring ordering and diagnostic round trip")
