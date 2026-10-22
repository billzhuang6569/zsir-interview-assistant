import SwiftUI
import AppKit
import RecordingCore

struct CaptureSettings: View {
    @ObservedObject var model: CaptureModel
    @State private var advanced = false
    @State private var refresh = 0
    private let accent = Color(red: 1, green: 0.40, blue: 0.15)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    if advanced { Button { advanced = false } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain) }
                    Text(advanced ? "高级设置" : "录制设置").font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Button { model.settingsVisible = false } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }.accessibilityLabel("关闭设置")
                }
                if advanced { advancedSettings } else { SettingsSources(model: model, preview: model.settingsPreview, refresh: $refresh) }
                Divider().padding(.top, 10)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(advanced ? "版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版")" : "保存到 \(model.root.path)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if !advanced { Button("高级设置 ›") { advanced = true }.buttonStyle(.plain).foregroundStyle(accent) }
                    }
                    Spacer()
                    Button(advanced ? "返回" : "完成") {
                        if advanced { advanced = false } else { model.settingsVisible = false }
                    }.buttonStyle(RecordingAccentButtonStyle())
                }
            }.padding(28)
        }.frame(width: 720, height: min(860, max(500, (NSScreen.main?.visibleFrame.height ?? 900) - 100)))
            .background(Color(white: 0.075))
            .onDisappear { Task { await model.settingsPreview.stop() } }
    }
    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !RecordingCapabilities.macOS12Edition { UpdateSettings(updates: model.updates); Divider() }
            Text("一般不需要改动，默认值已按采访录制调好。").font(.caption).foregroundStyle(.secondary)
            HStack { VStack(alignment: .leading) { Text("保存位置"); Text(model.root.path).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("更改…") { model.chooseFolder() } }
            Divider()
            Toggle("意外中断后自动恢复", isOn: $model.autoRecovery).tint(accent)
            Text("下次打开时恢复已写入片段为副本，保留原文件；不会自动继续录制。").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack { Text("系统权限"); Spacer(); Button("权限设置…") {
                model.settingsVisible = false
                DispatchQueue.main.async { model.permissions.present(for: model.mode, busy: model.busy) }
            } }
            HStack { Text("重新检测设备"); Spacer(); Button("检测") { model.refreshDevices(); refresh += 1 } }
            Text("插拔设备后自动更新，检测不会替换失联的录制目标。").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack { Text("异常中断恢复"); Spacer(); Button("重新检查") { model.scanRecovery() } }
            if model.recoverable.isEmpty { Text("未发现待恢复素材").foregroundStyle(.secondary) }
            ForEach(model.recoverable) { item in
                HStack { Text(item.folder.lastPathComponent).font(.caption); Spacer(); Button("恢复副本") { model.settingsVisible = false; model.recover(item) } }
            }
        }.padding(20).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16)).disabled(model.busy)
    }
}

private struct SettingsSources: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var preview: SettingsPreview
    @Binding var refresh: Int
    @Environment(\.scenePhase) private var scenePhase
    @State private var permissionRevision = 0
    private let accent = Color(red: 1, green: 0.4, blue: 0.15)
    private var cameraAllowed: Bool { CapturePermission.status(.camera) == .allowed && CapturePermission.status(.microphone) == .allowed }
    private var screenAllowed: Bool { CapturePermission.status(.screen) == .allowed }
    private var taskID: String {
        let screens = model.displays.map { "\($0.id):\(CGDisplayPixelsWide(UInt32($0.id) ?? 0))x\(CGDisplayPixelsHigh(UInt32($0.id) ?? 0))" }.joined()
        return "\(model.selection.cameraID)|\(model.selection.microphoneID)|\(model.mode.rawValue)|\(screens)|\(model.cameras.map(\.id))|\(model.microphones.map(\.id))|\(refresh)|\(permissionRevision)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.mode.includesCamera { cameraCard }
            if model.mode.includesDesktop { desktopCard }
            HStack { Text("画质").fontWeight(.semibold); Spacer(); Text(capacity).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 4) {
                ForEach(RecordingQuality.allCases) { quality in
                    Button { model.quality = quality } label: {
                        HStack(spacing: 6) {
                            Text(quality.title)
                            if quality == .standard { Text("推荐").font(.system(size: 10, weight: .medium)).foregroundStyle(Color(red: 1, green: 0.54, blue: 0.36)).padding(.horizontal, 6).padding(.vertical, 2).background(Color(red: 0.23, green: 0.14, blue: 0.10), in: Capsule()) }
                        }.frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(model.quality == quality ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).accessibilityAddTraits(model.quality == quality ? .isSelected : [])
                }
            }.padding(4).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }.disabled(model.busy)
            .task(id: taskID) { if !model.busy { await preview.refresh(selection: model.selection, mode: model.mode) } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissionRevision += 1 }
            .onDisappear { Task { await preview.stop() } }
    }
    private func badge(_ text: String, ready: Bool) -> some View {
        Label(text, systemImage: "circle.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(ready ? Color.green : Color.orange)
            .padding(.horizontal, 9).padding(.vertical, 5).background((ready ? Color.green : Color.orange).opacity(0.12), in: Capsule())
    }
    private var cameraCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("摄像头与麦克风", systemImage: "video").font(.headline); Spacer(); badge(cameraAllowed ? (preview.cameraError == nil ? "预览与声音检测" : "设备不可用") : "需要授权", ready: cameraAllowed && preview.cameraError == nil) }
            HStack(alignment: .top, spacing: 16) {
                SettingsCameraImage(feed: preview.feed).frame(width: 224, height: 132).clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 8) {
                    picker("摄像头", value: $model.selection.cameraID, options: model.cameras)
                    picker("麦克风", value: $model.selection.microphoneID, options: model.microphones)
                    HStack(spacing: 4) { ForEach(0..<12) { index in Capsule().fill(preview.level > Double(index) / 12 ? Color.green : Color.white.opacity(0.08)).frame(height: 5) } }.accessibilityLabel("麦克风电平 \(Int(preview.level * 100))%")
                }
            }
            if let error = preview.cameraError { Text(error).font(.caption).foregroundStyle(.orange) }
            if !cameraAllowed { Button("允许摄像头与麦克风") { Task {
                for permission in [CapturePermission.camera, .microphone] {
                    if CapturePermission.status(permission) == .notDetermined { await CapturePermission.request(permission) }
                    else if CapturePermission.status(permission) != .allowed { model.permissions.openSettings(for: permission); break }
                }
                permissionRevision += 1
            } } }
        }.padding(20).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }
    private func picker(_ label: String, value: Binding<String>, options: [DeviceOption]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Picker(label, selection: value) {
                Text("系统当前默认").tag("")
                ForEach(options) { Text($0.name).tag($0.id) }
                if !value.wrappedValue.isEmpty && !options.contains(where: { $0.id == value.wrappedValue }) { Text("设备已断开，请重选").tag(value.wrappedValue) }
            }.labelsHidden().frame(maxWidth: .infinity).controlSize(.large)
        }
    }
    private var desktopCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label("桌面画面", systemImage: "desktopcomputer").font(.headline); Spacer(); badge(screenAllowed ? "选择录制目标" : "需要屏幕录制权限", ready: screenAllowed) }
            if !RecordingCapabilities.systemAudio {
                Text("macOS 12 兼容版：桌面仅录画面，不录系统播放声音。").font(.caption).foregroundStyle(.orange)
            }
            if screenAllowed {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(model.displays) { display in
                            let id = UInt32(display.id) ?? 0
                            Button { model.selection.displayID = id } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack {
                                        Color.black.opacity(0.25)
                                        if let image = preview.thumbnails[id] { Image(nsImage: image).resizable().scaledToFit() }
                                        else { Label("预览暂不可用", systemImage: "display").foregroundStyle(.secondary) }
                                    }.frame(height: 112).clipShape(RoundedRectangle(cornerRadius: 8))
                                    HStack { Image(systemName: model.selection.displayID == id ? "largecircle.fill.circle" : "circle"); Text(display.name).lineLimit(1); Spacer(); if model.selection.displayID == id { Text("已选择").font(.caption).foregroundStyle(accent) } }
                                    Text(dimensions(id)).font(.caption2).foregroundStyle(.secondary)
                                }.padding(10).frame(width: 286).background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selection.displayID == id ? accent : Color.white.opacity(0.08), lineWidth: model.selection.displayID == id ? 2 : 1))
                            }.buttonStyle(.plain).accessibilityLabel("\(display.name)，\(dimensions(id))").accessibilityAddTraits(model.selection.displayID == id ? .isSelected : [])
                        }
                    }.padding(2)
                }
                if !model.displays.contains(where: { $0.id == String(model.selection.displayID) }) { Text("原目标屏幕已断开，请重新选择；不会自动录制其他屏幕。").font(.caption).foregroundStyle(.orange) }
                if let error = preview.screenError { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("同时录下电脑里播放的声音"); Text(RecordingCapabilities.systemAudio ? "视频、音乐、通话对方的声音都会被录进桌面视频" : "兼容版不支持系统声音；桌面视频无声音，摄像头仍可录话筒").font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Toggle("录制系统声音", isOn: $model.systemAudio).labelsHidden().toggleStyle(.switch).tint(accent).disabled(!RecordingCapabilities.systemAudio)
                }.padding(12).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "lock").font(.title).foregroundStyle(.orange)
                    Text("系统还没允许我们录制你的屏幕").fontWeight(.medium)
                    Text("开启「\(RecordingCapabilities.applicationName)」的开关后返回检测。").font(.caption).foregroundStyle(.secondary)
                    HStack { Button("打开系统设置") { model.permissions.openSettings(for: .screen) }.buttonStyle(RecordingAccentButtonStyle()); Button("我已允许，重新检测") { permissionRevision += 1 } }
                }.frame(maxWidth: .infinity).padding(24).background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(20).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
    }
    private func dimensions(_ id: UInt32) -> String {
        if let size = preview.sizes[id] { return "\(Int(size.width)) × \(Int(size.height))" }
        return "\(CGDisplayPixelsWide(id)) × \(CGDisplayPixelsHigh(id)) · 待检测实际采集尺寸"
    }
    private var capacity: String {
        var rate = model.mode.includesCamera ? Double(model.quality.cameraBitRate + 192_000) : 0
        if model.mode.includesDesktop {
            guard let size = preview.sizes[model.selection.displayID], let desktop = try? model.quality.desktopBitRate(width: Int(size.width), height: Int(size.height)) else { return "选择屏幕并授权后估算容量" }
            rate += Double(desktop + (model.systemAudio ? 192_000 : 0))
        }
        return String(format: "成品合计约 %.1f GB / 小时", rate / 1_000_000 * 0.45)
    }
}

private struct SettingsCameraImage: View {
    @ObservedObject var feed: LivePreviewFeed
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.4)
            if let frame = feed.frame { VideoSurface(sample: frame.sample) }
            else { Image(systemName: "person.fill").font(.system(size: 52)).foregroundStyle(.white.opacity(0.15)).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if feed.frame != nil { Label("实时预览", systemImage: "circle.fill").font(.system(size: 9)).foregroundStyle(.red).padding(6).background(.black.opacity(0.7), in: Capsule()).padding(8) }
        }
    }
}
