import SwiftUI

struct CaptureSettings: View {
    @ObservedObject var model: CaptureModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("录制设置").font(.title2.bold())
                Spacer()
                Button("完成") { model.settingsVisible = false }.keyboardShortcut(.defaultAction)
            }
            Text("录制前选择设备；录制中保持设备连接。").foregroundStyle(.secondary)
            Form {
                devicePicker("摄像头", selection: $model.selection.cameraID, options: model.cameras)
                    .disabled(!model.mode.includesCamera)
                devicePicker("话筒", selection: $model.selection.microphoneID, options: model.microphones)
                    .disabled(!model.mode.includesCamera)
                devicePicker("显示器", selection: Binding(get: {
                    model.selection.displayID == 0 ? "" : String(model.selection.displayID)
                }, set: { model.selection.displayID = UInt32($0) ?? 0 }), options: model.displays)
                    .disabled(!model.mode.includesDesktop)
                LabeledContent("系统声音", value: "全部系统播放声音")
            }.disabled(model.busy)
            HStack {
                Text("默认跟随系统当前设备；失联设备不会自动替换。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新设备") { model.refreshDevices() }.disabled(model.busy)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("素材目录").font(.headline)
                    Text(model.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("更改…") { model.chooseFolder() }.disabled(model.busy)
            }
            Divider()
            HStack {
                Text("异常中断恢复").font(.headline)
                Spacer()
                Button("重新检查") { model.scanRecovery() }.disabled(model.busy)
            }
            Text("恢复已写入磁盘的片段，生成独立副本；原文件始终保留。中断前的末尾片段可能丢失。").font(.caption).foregroundStyle(.secondary)
            if model.recoverable.isEmpty {
                Label("未发现待恢复素材", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.recoverable) { candidate in
                            HStack {
                                Text(candidate.folder.lastPathComponent).font(.caption).lineLimit(2)
                                Spacer()
                                Button("恢复副本") { model.recover(candidate); model.settingsVisible = false }.disabled(model.busy)
                            }
                        }
                    }
                }.frame(maxHeight: 130)
            }
        }.padding(24).frame(width: 470)
    }

    private func devicePicker(_ title: String, selection: Binding<String>, options: [DeviceOption]) -> some View {
        Picker(title, selection: selection) {
            Text("系统当前默认").tag("")
            ForEach(options) { option in Text(option.name).tag(option.id) }
            if !selection.wrappedValue.isEmpty && !options.contains(where: { $0.id == selection.wrappedValue }) {
                Text("所选设备已断开，请重选").tag(selection.wrappedValue)
            }
        }
    }
}
