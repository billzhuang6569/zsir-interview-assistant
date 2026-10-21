import Foundation

// EOF means the UI disappeared, not a request to stop immediately.
final class StdinControl {
    private let input: FileHandle
    private let queue = DispatchQueue(label: "zsir.stdin")
    private let grace: TimeInterval
    private let stop: () -> Void
    private var buffer = Data()
    private var discarding = false
    init(input: FileHandle = .standardInput, grace: TimeInterval = 60, stop: @escaping () -> Void) {
        self.input = input; self.grace = grace; self.stop = stop
    }
    func start() {
        input.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in self?.receive(data) }
        }
    }
    private func receive(_ data: Data) {
        if data.isEmpty {
            input.readabilityHandler = nil
            queue.asyncAfter(deadline: .now() + grace, execute: stop)
            return
        }
        for byte in data {
            if byte == 10 {
                if !discarding, String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "stop" { stop() }
                buffer.removeAll(keepingCapacity: true); discarding = false
            } else if buffer.count < 4096, !discarding { buffer.append(byte) }
            else { discarding = true; buffer.removeAll(keepingCapacity: true) }
        }
    }
    deinit { input.readabilityHandler = nil }
}
