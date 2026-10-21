import Foundation

struct JSONLines {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var values: [[String: Any]] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            buffer.removeSubrange(...end)
            if line.isEmpty { continue }
            guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw NSError(domain: "RecorderJSON", code: 1, userInfo: [NSLocalizedDescriptionKey: "录制器返回了无效状态"])
            }
            values.append(value)
        }
        guard buffer.count < 1_048_576 else { throw NSError(domain: "RecorderJSON", code: 2) }
        return values
    }
}

// One serial reader drains stdout through EOF before delivering process completion.
final class RecorderBridge {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var log: FileHandle?
    private let writeLock = NSLock()
    private var inputClosed = false
    var pid: Int32 { process.processIdentifier }

    func start(executable: URL, arguments: [String], logURL: URL?,
               event: @escaping ([String: Any]) -> Void,
               completion: @escaping (Int32, String?) -> Void) throws {
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = input; process.standardOutput = output
        if let logURL {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            log = try FileHandle(forWritingTo: logURL)
        }
        process.standardError = log ?? FileHandle.nullDevice
        try process.run()
        input.fileHandleForReading.closeFile(); output.fileHandleForWriting.closeFile()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var parser = JSONLines()
            var error: String?
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                try? log?.write(contentsOf: data)
                do {
                    for value in try parser.append(data) { DispatchQueue.main.async { event(value) } }
                } catch let failure { error = failure.localizedDescription }
            }
            process.waitUntilExit()
            closeInput()
            output.fileHandleForReading.closeFile(); log?.closeFile()
            let status = process.terminationStatus
            let parseError = error
            DispatchQueue.main.async { completion(status, parseError) }
        }
    }
    func stop() throws {
        writeLock.lock(); defer { writeLock.unlock() }
        guard !inputClosed else { return }
        try input.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
    }
    private func closeInput() {
        writeLock.lock(); defer { writeLock.unlock() }
        if !inputClosed { input.fileHandleForWriting.closeFile(); inputClosed = true }
    }
}
