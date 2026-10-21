import AppKit
import AVFoundation
import RecordingCore

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

@MainActor
enum PermissionSetupChecks {
    static func run() async {
        let name = "com.zsir.permission-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var states: [CapturePermission: PermissionStatus] = [.camera: .notDetermined, .microphone: .denied, .screen: .unconfirmed]
        var requests: [CapturePermission] = []
        var continuation: CheckedContinuation<Void, Never>?
        let setup = PermissionSetup(defaults: defaults, readStatus: { states[$0]! }, requestAccess: { permission in
            requests.append(permission)
            await withCheckedContinuation { continuation = $0 }
            states[permission] = .allowed
        })
        precondition(CapturePermission.required(for: .camera) == [.camera, .microphone])
        precondition(CapturePermission.required(for: .desktop) == [.screen])
        precondition(CapturePermission.required(for: .both) == [.camera, .microphone, .screen])
        precondition(PermissionStatus(.authorized) == .allowed)
        precondition(PermissionStatus(.denied) == .denied)
        precondition(PermissionStatus(.restricted) == .restricted)
        precondition(PermissionStatus(.notDetermined) == .notDetermined)
        setup.present(for: .camera, busy: true, firstLaunch: true)
        precondition(!setup.visible)
        setup.present(for: .camera, busy: false, firstLaunch: true)
        precondition(setup.visible && setup.step == 0 && !setup.ready(for: .camera))
        precondition(setup.statuses[.screen] == nil, "Unselected permissions are not checked")
        setup.finish(for: .camera)
        precondition(!setup.completed && setup.visible)
        await setup.request(.screen, for: .camera)
        await setup.request(.microphone, for: .camera)
        precondition(requests.isEmpty, "Never request an unselected or denied permission")
        let pending = Task { await setup.request(.camera, for: .camera) }
        while continuation == nil { await Task.yield() }
        precondition(setup.requesting == .camera)
        await setup.request(.camera, for: .camera)
        precondition(requests == [.camera], "Repeated clicks cannot issue overlapping requests")
        setup.visible = false
        continuation?.resume()
        await pending.value
        precondition(!setup.visible && setup.requesting == nil && !setup.completed, "Late completion cannot reopen or finish onboarding")
        setup.step = 1
        let reopened = PermissionSetup(defaults: defaults, readStatus: { states[$0]! })
        reopened.present(for: .camera, busy: false, firstLaunch: true)
        precondition(reopened.visible && reopened.step == 1 && !reopened.completed)
        states[.microphone] = .allowed
        reopened.refresh(for: .camera)
        precondition(reopened.ready(for: .camera))
        reopened.step = 2
        states[.microphone] = .restricted
        reopened.refresh(for: .camera)
        precondition(reopened.step == 1 && !reopened.ready(for: .camera))
        states[.microphone] = .allowed
        reopened.finish(for: .camera)
        precondition(reopened.completed && !reopened.visible)
        reopened.present(for: .camera, busy: false, firstLaunch: true)
        precondition(!reopened.visible, "Completed setup skips automatic welcome")
        let model = CaptureModel(permissions: reopened)
        precondition(model.detail.isEmpty)
        precondition(model.mode.title == "摄像头+桌面")
        model.mode = .camera
        precondition(defaults.string(forKey: "recordingMode") == "camera")
        precondition(CaptureModel(permissions: reopened).mode == .camera)
        model.mode = .desktop
        model.start()
        precondition(reopened.visible && !model.busy && model.lastTake == nil, "Missing permission must block before capture or Take creation")
        reopened.visible = false
        model.busy = true
        model.start()
        precondition(!reopened.visible)
        reopened.present(for: .desktop, busy: model.busy)
        precondition(!reopened.visible)
        model.busy = false
        states[.screen] = .allowed
        reopened.present(for: .desktop, busy: false)
        precondition(reopened.ready(for: .desktop))
        states[.screen] = .unconfirmed
        reopened.finish(for: .desktop)
        precondition(reopened.visible && !reopened.ready(for: .desktop), "Completion always rechecks system permission")
        print("PASS: permission mapping, denied/restricted states, serial requests, late callback, skip/resume, completion/revocation, persisted mode, pre-capture gate, busy guard, copy")
    }
}
