import AppKit
import SwiftUI

@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()
    private var panel: NSPanel?
    private var activation: NSObjectProtocol?
    private var tracking: Timer?
    func show() {
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isMovable = false; panel.isMovableByWindowBackground = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        let content = NSHostingView(rootView: PermissionGuideView().preferredColorScheme(.dark))
        panel.contentView = content
        panel.setContentSize(NSSize(width: 390, height: max(300, content.fittingSize.height)))
        panel.title = "录屏权限引导"
        self.panel = panel
        followSettings()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followSettings() }
        }
        tracking = timer
        RunLoop.main.add(timer, forMode: .common)
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }
    private func followSettings() {
        guard let panel else { return }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let info = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
                  ($0[kCGWindowLayer as String] as? Int) == 0
              }),
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds),
              let primary = NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        // Core Graphics uses the primary screen's top-left; AppKit uses its bottom-left.
        let target = NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        guard let screen = NSScreen.screens.max(by: {
            let a = $0.frame.intersection(target), b = $1.frame.intersection(target)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }) else { return }
        guard let origin = Self.origin(beside: target, size: panel.frame.size, visible: screen.visibleFrame) else {
            panel.orderOut(nil)
            return
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    static func origin(beside target: NSRect, size: NSSize, visible: NSRect) -> NSPoint? {
        let gap: CGFloat = 12
        let y = max(visible.minY, min(target.maxY - size.height, visible.maxY - size.height))
        for x in [target.maxX + gap, target.minX - gap - size.width] {
            let candidate = NSRect(origin: NSPoint(x: x, y: y), size: size)
            if visible.contains(candidate) && !candidate.intersects(target) { return candidate.origin }
        }
        // Never clamp horizontally into System Settings when neither side has room.
        return nil
    }

    func close() {
        tracking?.invalidate(); tracking = nil
        panel?.orderOut(nil); panel = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }; activation = nil
    }
}

private struct PermissionGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("录屏权限引导").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { PermissionGuide.shared.close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭引导")
            }
            Text("打开庄Sir采访录制助手的开关").font(.headline)
            Text("如果没有出现，拖动这里").font(.subheadline)
            HStack(spacing: 12) {
                Image(systemName: "arrow.left").foregroundStyle(.orange)
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundleURL.path)).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text("庄Sir采访录制助手").font(.subheadline)
                    Text("拖到系统设置的应用列表").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.8)))
                .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                .accessibilityLabel("拖动庄Sir采访录制助手应用到录屏权限列表")
            Text("也可点列表下方的 +，选择此应用。开启后返回检测。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("返回应用检测") {
                PermissionGuide.shared.close(); NSApp.activate(ignoringOtherApps: true)
            }.buttonStyle(RecordingAccentButtonStyle()) }
        }.padding(22).background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct RecordingAccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Color(red: 1, green: 0.40, blue: 0.15).opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
