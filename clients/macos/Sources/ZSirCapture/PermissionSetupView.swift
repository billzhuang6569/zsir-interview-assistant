import SwiftUI
import AppKit
import RecordingCore

struct PermissionSetupView: View {
    @ObservedObject var model: CaptureModel
    @ObservedObject var setup: PermissionSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 42, height: 42).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("准备好，再开始录制").font(.title2.bold())
                    Text("选择方式  →  允许权限  →  完成设置").font(.callout).foregroundStyle(.secondary)
                }
            }
            Divider()
            if setup.step == 0 {
                Text("你想录制什么？").font(.headline)
                modePicker
                Text("先完成所需权限设置。只有你点击「开始录制」，才会采集画面和声音；素材不会自动上传。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if setup.step == 1 {
                modePicker
                ForEach(CapturePermission.required(for: model.mode)) { permission in
                    permissionRow(permission)
                }
                Text("系统设置 → 隐私与安全性 → 摄像头 / 话筒 / 屏幕与系统音频录制（旧版系统称「屏幕录制」）。开启本应用后返回这里。若系统提示需要重新打开，请用 ⌘Q 退出后重新打开应用。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = setup.settingsError { Text(error).font(.caption).foregroundStyle(.orange) }
            } else {
                Label("权限设置完成", systemImage: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                Text("已准备好「\(model.mode.title)」所需权限。进入小窗后选择设备和保存位置，再点击「开始录制」。建议先做一次短试录，检查画面与声音。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("稍后设置") { setup.visible = false }.keyboardShortcut(.cancelAction)
                Spacer()
                if setup.step > 0 {
                    Button("上一步") { setup.step -= 1 }.disabled(setup.requesting != nil)
                }
                if setup.step == 1 {
                    Button("重新检查") { setup.refresh(for: model.mode) }.disabled(setup.requesting != nil)
                }
                Button(setup.step == 2 ? "进入录制小窗" : "下一步") {
                    setup.refresh(for: model.mode)
                    if setup.step == 2 { setup.finish(for: model.mode) }
                    else if setup.step == 0 || setup.ready(for: model.mode) { setup.step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(setup.requesting != nil || (setup.step == 1 && !setup.ready(for: model.mode)))
            }
        }
        .padding(28).frame(width: 560).fixedSize(horizontal: false, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            setup.refresh(for: model.mode)
        }
        .onChange(of: model.mode) { _, _ in setup.refresh(for: model.mode) }
    }

    private var modePicker: some View {
        Picker("录制方式", selection: $model.mode) {
            ForEach(RecordingMode.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).disabled(setup.requesting != nil)
    }

    private func permissionRow(_ permission: CapturePermission) -> some View {
        let status = setup.statuses[permission] ?? .unconfirmed
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(permission.title, systemImage: status == .allowed ? "checkmark.circle.fill" : "lock.circle")
                    .font(.headline).foregroundStyle(status == .allowed ? .green : .primary)
                Spacer()
                if setup.requesting == permission {
                    ProgressView().controlSize(.small).accessibilityLabel("等待系统授权")
                } else if status == .notDetermined || (permission == .screen && status == .unconfirmed) {
                    Button("允许\(permission.title)") { Task { await setup.request(permission, for: model.mode) } }
                        .disabled(setup.requesting != nil)
                }
                if status == .denied || (permission == .screen && status == .unconfirmed) {
                    Button("打开系统设置") { setup.openSettings(for: permission) }
                        .disabled(setup.requesting != nil)
                        .accessibilityLabel("打开\(permission.title)系统设置")
                }
            }
            Text(permission.purpose).font(.callout).foregroundStyle(.secondary)
            Text(status.title).font(.caption).foregroundStyle(status == .allowed ? .green : .secondary)
        }.padding(14).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}
