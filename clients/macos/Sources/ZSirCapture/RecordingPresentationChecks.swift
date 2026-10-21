import AppKit

@MainActor
enum RecordingPresentationChecks {
    static func run() {
        checkTimecode()
        checkDocking()
        print("PASS: timecode formatting, ready gate, idle timeout, interaction reset, reopen grace, failure and stop restoration")
    }
    static func checkTimecode() {
        let model = CaptureModel()
        for (seconds, expected) in [(0.0, "00:00:00"), (59.9, "00:00:59"), (3601, "01:00:01"), (360_000, "100:00:00")] {
            model.recordedSeconds = seconds
            precondition(model.timecode == expected)
        }
    }

    static func checkDocking() {
        _ = NSApplication.shared
        let model = CaptureModel()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 336, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = RecordingEdgeController(model: model, window: window, startTimer: false)
        defer { window.close() }
        controller.tick(now: 0)
        controller.tick(now: 100)
        precondition(!controller.isDocked, "Idle app must remain expanded")
        model.canStop = true
        model.phase = "等待录制数据…"
        controller.tick(now: 120)
        precondition(!controller.isDocked, "Unhealthy or unready recordings must remain visible")
        model.phase = "正在录制"
        controller.tick(now: 200)
        controller.tick(now: 214)
        precondition(!controller.isDocked)
        controller.interact(now: 214)
        controller.tick(now: 228)
        precondition(!controller.isDocked, "Interaction resets the delay")
        controller.tick(now: 229)
        precondition(controller.isDocked)
        controller.reveal(activate: false, now: 230)
        controller.tick(now: 244)
        precondition(!controller.isDocked, "Reopen must grant a full fresh idle period")
        controller.tick(now: 245)
        precondition(controller.isDocked)
        model.error = "测试设备中断"
        controller.tick(now: 246)
        precondition(!controller.isDocked, "Error must reveal the main window")
        model.error = nil
        controller.tick(now: 250)
        controller.tick(now: 265)
        precondition(controller.isDocked)
        model.canStop = false
        controller.tick(now: 266)
        precondition(!controller.isDocked, "Saving/stopping must reveal the main window")
    }
}
