import AppKit
import SwiftUI
import Shared

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    var floating: NSPanel!
    var setup: NSWindow!
    var status: NSStatusItem!
    var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        signal(SIGPIPE, SIG_IGN)
        // Reuse the existing instance instead of opening a second recorder UI.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "work.zsir.interview").contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil); return
        }
        floating = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 96), styleMask: [.borderless, .nonactivatingPanel, .hudWindow], backing: .buffered, defer: false)
        floating.identifier = NSUserInterfaceItemIdentifier("floating")
        floating.level = .floating; floating.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        floating.isFloatingPanel = true; floating.hidesOnDeactivate = false
        floating.isMovableByWindowBackground = true; floating.isOpaque = false; floating.backgroundColor = .clear
        floating.sharingType = .none; floating.hasShadow = true; floating.delegate = self
        floating.contentView = NSHostingView(rootView: FloatingView(model: model))
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        var origin = NSPoint(x: visible.maxX - 296, y: visible.maxY - 112)
        if let point = model.defaults.string(forKey: "floatOrigin") {
            let saved = NSPointFromString(point)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSRect(origin: saved, size: NSSize(width: 280, height: 96))) }) { origin = saved }
        }
        floating.setFrameOrigin(origin)
        setup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        setup.title = "庄Sir线上采访助手"; setup.isReleasedWhenClosed = false; setup.sharingType = .none; setup.delegate = self
        setup.contentView = NSHostingView(rootView: SetupView(model: model)); setup.center()
        model.presentSetup = { [weak self] in self?.showSetup() }
        model.presentFloat = { [weak self] in self?.showFloat() }
        model.finishSetup = { [weak self] in self?.hideSetup() }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "就绪 · 本地使用", action: nil, keyEquivalent: "")
        for (title, action) in [("打开浮窗", #selector(showFloat)), ("设置", #selector(showSettings)), ("打开输出目录", #selector(openOutput)), ("退出", #selector(quit))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); item.target = self
        }
        status.menu = menu
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            status.button?.title = model.busy ? "● 庄Sir" : "庄Sir"
            status.button?.toolTip = model.title
            status.menu?.items.first?.title = model.title
        }
        model.activate(); showFloat()
        if !model.defaults.bool(forKey: "onboarded") && !model.busy { showSetup() }
        NSLog("庄Sir App %@ launched; pid=%d", appVersion, getpid())
    }
    @objc func showFloat() { floating.orderFrontRegardless() }
    @objc func showSettings() { guard !model.busy && !model.checking else { showFloat(); return }; model.settings = true; showSetup() }
    @objc func openOutput() { model.openSaved() }
    func showSetup() {
        guard !model.busy else { showFloat(); return }
        model.setupVisible = true; model.updatePreview()
        setup.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func hideSetup() {
        model.setupVisible = false; model.updatePreview(); setup.orderOut(nil); showFloat()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === setup { if model.checking { return false }; hideSetup(); return false }
        return true
    }
    func windowDidMove(_ notification: Notification) {
        if notification.object as? NSPanel === floating { model.defaults.set(NSStringFromPoint(floating.frame.origin), forKey: "floatOrigin") }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showFloat(); return true }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.busy || model.checking {
            let alert = NSAlert(); alert.messageText = "请先停止录制并等待保存完成。"; alert.informativeText = "保存完成后即可退出。"; alert.runModal(); showFloat()
            return .terminateCancel
        }
        return .terminateNow
    }
}
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
