import SwiftUI

private let backdrop = Color(red: 0.078, green: 0.082, blue: 0.094)
private let panelColor = Color(red: 0.114, green: 0.122, blue: 0.141)
private let recordRed = Color(red: 0.898, green: 0.282, blue: 0.302)

struct Meter: View {
    let db: Double
    var body: some View {
        ProgressView(value: min(1, max(0, (db + 60) / 60)))
            .tint(.green).frame(width: 42).accessibilityLabel("话筒音量 \(Int(db)) 分贝")
    }
}
struct FloatingView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if model.phase == "countdown" {
                HStack(spacing: 12) {
                    Text("\(model.countdown)").font(.system(size: 42, weight: .bold, design: .monospaced)).foregroundColor(recordRed)
                    VStack(alignment: .leading) { Text("即将开始录制").bold(); Text("文件仅保存在本机").font(.caption) }
                    Spacer()
                    Button("取消") { model.stop() }.font(.caption)
                }
            } else {
                HStack(spacing: 5) {
                    Circle().fill(model.phase == "error" ? recordRed : model.busy ? recordRed : .green).frame(width: 8, height: 8)
                    Text(model.title).bold().lineLimit(1)
                    if model.phase == "recording" { Text(time).monospacedDigit().font(.caption) }
                    Spacer(minLength: 0)
                    Button { model.settings = true; model.presentSetup?() } label: { Image(systemName: "gearshape") }
                        .disabled(model.busy || model.checking).accessibilityLabel("打开设置")
                    Button { NSApp.windows.first(where: { $0.identifier?.rawValue == "floating" })?.orderOut(nil) } label: { Image(systemName: "minus") }.accessibilityLabel("收起浮窗")
                }.buttonStyle(.plain)
                if model.phase == "error" || model.phase == "recovering" {
                    Text(model.message).font(.system(size: 10)).foregroundColor(model.phase == "error" ? recordRed : .orange).lineLimit(2).help(model.message)
                } else if !model.warning.isEmpty {
                    Text("⚠ \(model.warning)").font(.caption).foregroundColor(.orange)
                } else {
                    HStack(spacing: 7) {
                        ForEach(["cam", "screen"], id: \.self) { track in
                            if model.scope.contains(track) {
                                Text("\(track == "cam" ? "摄像头" : "屏幕") \(model.tracks[track]?["ok"] as? Bool == true ? "✓" : "—")").font(.system(size: 10))
                            }
                        }
                        Meter(db: model.levels["cam"] ?? -120)
                        Meter(db: model.levels["screen"] ?? -120).accessibilityLabel("系统声音量")
                    }
                }
                HStack {
                    if model.saved != nil {
                        Button("已保存到…") { model.openSaved() }.help(model.message).font(.system(size: 10))
                    } else { Text(String(format: "剩余 %.1f GB", Double(model.disk) / 1e9)).font(.system(size: 10)).foregroundColor(.secondary) }
                    Spacer()
                    if model.phase == "starting" || model.phase == "recording" {
                        Button("停止录制") { model.stop() }
                    } else if model.busy { ProgressView().controlSize(.small) }
                    else {
                        Button(model.phase == "error" ? "重新自检" : "开始录制") {
                            if model.phase == "error" { model.settings = false; model.presentSetup?(); model.go(4) }
                            else { model.start() }
                        }.tint(recordRed).disabled(model.checking)
                    }
                }.controlSize(.small)
            }
        }.font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(width: 280, height: 96).background(backdrop)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.phase == "error" ? recordRed : model.warning.isEmpty ? Color.gray.opacity(0.4) : .orange))
            .clipShape(RoundedRectangle(cornerRadius: 12)).preferredColorScheme(.dark)
    }
    private var time: String { let t = Int(model.elapsed); return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) }
}

struct PreviewTiles: View {
    @ObservedObject var preview: Preview
    var body: some View {
        HStack {
            tile(preview.cameraImage, "摄像头预览")
            tile(preview.screenImage, "屏幕预览")
        }
    }
    private func tile(_ image: NSImage?, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Color.black
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else { Text("暂无预览").foregroundColor(.secondary) }
            }.frame(height: 114).clipShape(RoundedRectangle(cornerRadius: 6))
            Text(title).font(.caption).foregroundColor(.secondary)
        }
    }
}
struct DeviceSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preview: Preview
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            picker("摄像头", $model.camera, model.cameras)
            picker("话筒", $model.mic, model.mics)
            picker("显示器", $model.display, model.displays)
            HStack { Text("话筒音量").font(.caption); Meter(db: preview.level); Spacer(); Button("刷新设备") { model.loadDevices() } }
            PreviewTiles(preview: preview)
            Text("此页正在预览摄像头、话筒和屏幕；离开后立即关闭。").font(.caption).foregroundColor(.secondary)
            if !preview.error.isEmpty { Text(preview.error).font(.caption).foregroundColor(.orange) }
        }
    }
    private func picker(_ title: String, _ selection: Binding<String>, _ devices: [Device]) -> some View {
        Picker(title, selection: selection) {
            Text("请选择").tag("")
            if !selection.wrappedValue.isEmpty && !devices.contains(where: { $0.id == selection.wrappedValue }) { Text("设备已断开，请重选").tag(selection.wrappedValue) }
            ForEach(devices) { Text($0.name).tag($0.id) }
        }
    }
}
struct SetupView: View {
    @ObservedObject var model: AppModel
    private let steps = ["欢迎", "系统权限", "选择设备", "自检", "输入邀请码 · 稍后", "欢迎卡 · 稍后"]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("庄Sir\n线上采访助手").font(.headline).padding(.bottom, 16)
                ForEach(0..<6) { index in
                    HStack { Text(index + 1 < model.step ? "✓" : "\(index + 1)").frame(width: 22); Text(steps[index]).font(.system(size: 12)) }
                        .foregroundColor(index + 1 == model.step && !model.settings ? .white : .secondary)
                        .padding(.vertical, 7)
                        .background(index + 1 == model.step && !model.settings ? Color.white.opacity(0.08) : .clear).cornerRadius(6)
                }
                Spacer()
                Text("无需联网 · 本地录制").font(.caption).foregroundColor(.secondary)
            }.padding(18).frame(width: 180).background(backdrop)
            VStack(alignment: .leading, spacing: 14) {
                Text(model.settings ? "设置" : steps[model.step - 1]).font(.system(size: 23, weight: .bold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        content
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                if !model.message.isEmpty && model.phase == "error" { Text(model.message).font(.caption).foregroundColor(.red).textSelection(.enabled) }
                HStack {
                    if model.settings {
                        Button("重新引导") { model.settings = false; model.go(1) }
                        Spacer()
                        Button("完成") { model.finishSetup?() }.keyboardShortcut(.defaultAction)
                    } else {
                        if model.step > 1 { Button("上一步") { model.go(model.step - 1) }.disabled(model.checking) }
                        Spacer()
                        if model.step >= 5 {
                            Button("直接本地使用") { model.defaults.set(true, forKey: "onboarded"); model.phase = "ready"; model.message = ""; model.finishSetup?() }.keyboardShortcut(.defaultAction)
                            if model.step == 5 { Button("下一步：欢迎卡") { model.go(6) } }
                        } else {
                            Button(model.step == 4 ? "下一步：输入邀请码" : "下一步") { model.go(model.step + 1) }
                                .disabled(!canContinue).keyboardShortcut(.defaultAction)
                        }
                    }
                }
            }.padding(24).frame(maxWidth: .infinity).background(panelColor)
        }.frame(width: 800, height: 560).preferredColorScheme(.dark)
    }
    private var canContinue: Bool {
        if model.step == 2 { return model.permissions.allSatisfy { $0 } }
        if model.step == 3 { return model.cameras.contains { $0.id == model.camera } && model.mics.contains { $0.id == model.mic } && model.displays.contains { $0.id == model.display } }
        if model.step == 4 { return model.preflightOK }
        return true
    }
    @ViewBuilder private var content: some View {
        if model.settings {
            DeviceSettings(model: model, preview: model.preview)
            Picker("画质", selection: $model.quality) { Text("推荐").tag("recommended"); Text("高画质").tag("high"); Text("省空间").tag("saver") }
            Picker("录制范围", selection: $model.scope) { Text("两路").tag("cam,screen"); Text("仅摄像头 + 话筒").tag("cam"); Text("仅屏幕 + 系统声").tag("screen") }
            outputRow
        } else {
            switch model.step {
            case 1:
                Text("装好、检查、点击开始。采访文件留在您的电脑上。").font(.title3)
                promise("不录制时，不访问摄像头、麦克风和屏幕。", "您主动打开的设备预览和 3 秒自检会临时采集，离开后关闭。")
                promise("开始录制前一定有 3 秒倒计时。", "录制中浮窗显示红点与时长。")
                promise("录制文件只存在您的电脑上。", "本版本不联网、不上传；未来上传会显示进度并允许暂停。")
            case 2:
                Text("请逐项允许权限，再回到这里继续。").foregroundColor(.secondary)
                ForEach(0..<3) { index in
                    HStack {
                        Image(systemName: model.permissions[index] ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundColor(model.permissions[index] ? .green : .orange)
                        Text(["摄像头", "麦克风", "屏幕与系统音频录制"][index]); Spacer()
                        Text(model.permissions[index] ? "已授权" : "未授权").font(.caption)
                        Button("允许") { model.requestPermission(index) }.disabled(model.permissions[index])
                        Button("去设置") { model.openPermission(index) }
                    }.padding(.vertical, 10)
                }
                Text("系统设置 → 隐私与安全性 → 对应权限 → 打开「庄Sir线上采访助手」。屏幕授权后若仍不可用，请退出并重新打开应用。").font(.callout).foregroundColor(.secondary)
            case 3: DeviceSettings(model: model, preview: model.preview)
            case 4:
                Text(model.checking ? "正在做 3 秒试录，请对话筒说话并播放电脑声音…" : model.preflightOK ? "自检完成，可以继续了" : "检查录制环境").foregroundColor(model.preflightOK ? .green : .secondary)
                if model.checking { ProgressView() }
                // Preflight owns capture; these are the last device-page preview frames, never a second simultaneous capture.
                PreviewTiles(preview: model.preview)
                Text("缩略图为设备页最后预览；以下结果来自录制器本次自检。").font(.caption).foregroundColor(.secondary)
                result("摄像头 + 话筒", ok: (model.preflight?["cam"] as? [String: Any])?["ok"] as? Bool, detail: trackDetail("cam"))
                result("屏幕 + 系统声", ok: (model.preflight?["screen"] as? [String: Any])?["ok"] as? Bool, detail: trackDetail("screen"))
                result("系统声音频样本", ok: (model.preflight?["systemAudio"] as? [String: Any])?["ok"] as? Bool, detail: "请播放电脑声音")
                result("输出目录可写", ok: model.outputWritable, detail: model.outputWritable == true ? "已验证文件写入" : "等待目录检查")
                result("硬件编码", ok: model.preflight.map { ($0["encoder"] as? String ?? "unverified") != "unverified" }, detail: model.preflight?["encoder"] as? String ?? "等待检查")
                Text(String(format: "输出目录剩余 %.1f GB · 自检试录目录剩余 %.1f GB", Double(model.disk) / 1e9, (model.preflight?["diskFreeBytes"] as? Double ?? 0) / 1e9)).font(.caption)
                ForEach(Array(model.checkErrors.enumerated()), id: \.offset) { _, error in Text(AppModel.advice(error)).foregroundColor(.orange).font(.callout).textSelection(.enabled) }
                outputRow
                Button("重新自检") { model.runPreflight() }.disabled(model.checking)
            case 5:
                Text("输入邀请码（M4 开放）").font(.title2)
                Text("稍后可用。今天可以直接本地录制，无需邀请码。").foregroundColor(.secondary)
            default:
                Text("房间欢迎卡（M4 开放）").font(.title2)
                Text("稍后可用。您的设备已经准备好，可以直接本地使用。").foregroundColor(.secondary)
            }
        }
    }
    private func trackDetail(_ key: String) -> String {
        guard let track = model.preflight?[key] as? [String: Any] else { return "等待检查" }
        return "\(track["width"] as? Int ?? 0)×\(track["height"] as? Int ?? 0) · \(Int(track["levelDb"] as? Double ?? -120)) dB"
    }
    private var outputRow: some View { HStack { Text("输出到 \(model.output)").font(.caption).lineLimit(2).textSelection(.enabled); Spacer(); Button("更改") { model.chooseOutput() }.disabled(model.checking) } }
    private func promise(_ title: String, _ detail: String) -> some View { VStack(alignment: .leading, spacing: 5) { Label(title, systemImage: "checkmark.shield").foregroundColor(.green); Text(detail).font(.callout).foregroundColor(.secondary) }.padding(.vertical, 10) }
    private func result(_ label: String, ok: Bool?, detail: String) -> some View {
        HStack { Image(systemName: ok == true ? "checkmark.circle.fill" : ok == false ? "exclamationmark.circle" : "circle.dotted").foregroundColor(ok == true ? .green : .orange); Text(label); Spacer(); Text(detail).font(.caption).foregroundColor(.secondary) }
    }
}
