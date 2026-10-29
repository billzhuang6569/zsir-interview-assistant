import AppKit
import SwiftUI

@MainActor
final class RecordingEdgeController {
    static let idleDelay: TimeInterval = 15
    private let model: CaptureModel
    private let window: NSWindow
    private let indicator: NSPanel
    private var timer: Timer?
    private var activityMonitor: Any?
    private var eligibleLastTick = false
    private var lastInteraction = ProcessInfo.processInfo.systemUptime
    private(set) var isDocked = false

    init(model: CaptureModel, window: NSWindow, startTimer: Bool = true) {
        self.model = model
        self.window = window
        indicator = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 32, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        indicator.title = "正在录制 · 点击展开"
        indicator.isOpaque = false
        indicator.backgroundColor = .clear
        indicator.hasShadow = false
        indicator.hidesOnDeactivate = false
        indicator.level = .floating
        indicator.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        indicator.sharingType = .none
        indicator.isReleasedWhenClosed = false
        indicator.contentView = NSHostingView(rootView: RecordingEdgeIndicator(model: model) { [weak self] in self?.reveal(activate: true) })
        window.acceptsMouseMovedEvents = true
        if startTimer {
            activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel, .leftMouseDragged]) { [weak self] event in
                if event.window === self?.window { self?.interact() }
                return event
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(now: ProcessInfo.processInfo.systemUptime) }
            }
        }
    }

    func interact(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastInteraction = now }

    func tick(now: TimeInterval) {
        let eligible = model.canStop && model.phase == "正在录制" && model.error == nil && window.attachedSheet == nil
        if !eligible {
            eligibleLastTick = false
            lastInteraction = now
            if isDocked { reveal(activate: false) }
            return
        }
        if !eligibleLastTick { lastInteraction = now; eligibleLastTick = true }
        if isDocked { placeIndicator(); return }
        if now - lastInteraction >= Self.idleDelay {
            placeIndicator()
            isDocked = true
            model.setPreviewWindowVisible(false)
            window.orderOut(nil)
            indicator.orderFrontRegardless()
        }
    }

    private var screenFrame: NSRect {
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        return (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame ?? window.frame
    }

    private func placeIndicator() {
        let screen = screenFrame
        let origin = NSPoint(x: screen.maxX - 32, y: min(max(window.frame.midY - 20, screen.minY), screen.maxY - 40))
        if indicator.frame.origin != origin { indicator.setFrameOrigin(origin) }
    }

    func reveal(activate: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        indicator.orderOut(nil)
        isDocked = false
        model.setPreviewWindowVisible(true)
        lastInteraction = now
        let screen = screenFrame
        var frame = window.frame
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        window.setFrame(frame, display: true)
        if activate { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { window.orderFrontRegardless() }
    }

    deinit {
        timer?.invalidate()
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
    }
}

private struct RecordingEdgeIndicator: View {
    @ObservedObject var model: CaptureModel
    let expand: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var raised = false

    var body: some View {
        Button(action: expand) {
            Circle().strokeBorder(.red, lineWidth: 3)
                .background(Circle().fill(.black.opacity(0.65)))
                .frame(width: 19, height: 19)
                .offset(y: reduceMotion ? 0 : (raised ? -2 : 2))
                .frame(width: 32, height: 40).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .help("正在录制 \(model.timecode) · 点击展开")
        .accessibilityLabel("正在录制 \(model.timecode)，展开录制窗口")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: raised)
        .onAppear { raised = true }
    }
}
