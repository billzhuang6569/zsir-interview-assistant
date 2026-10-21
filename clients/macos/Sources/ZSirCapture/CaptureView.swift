import AppKit
import SwiftUI
import RecordingCore

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    private let accent = Color(red: 1, green: 0.39, blue: 0.20)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text("庄Sir采访录制助手").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("退出采访录制助手").accessibilityLabel("退出采访录制助手")
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Circle().fill(model.canStop ? accent : (model.busy || model.error != nil ? .orange : .mint))
                        .frame(width: 7, height: 7)
                    Text(model.phase).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text("本地保存").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(model.detail).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if model.canStop || model.recordedSeconds > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.timecode).font(.system(size: 28, weight: .medium, design: .monospaced))
                        .monospacedDigit().foregroundStyle(model.canStop ? accent : .secondary)
                        .accessibilityLabel("录制时长 \(model.timecode)")
                    Spacer()
                    Text(model.canStop ? "15 秒无操作后收起" : "本次录制时长")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Picker("录制机位", selection: $model.mode) {
                ForEach(RecordingMode.allCases) { mode in Text(mode.title).tag(mode) }
            }.pickerStyle(.segmented).labelsHidden().disabled(model.busy)

            VStack(spacing: 8) {
                Button { model.togglePreview() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.previewVisible ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        Text(model.previewVisible ? "收起预览" : "展开预览")
                        Spacer()
                        Text(model.canStop ? "实时画面" : (model.cameraPreview.frame != nil || model.desktopPreview.frame != nil ? "上次录制" : "尚未录制"))
                            .foregroundStyle(.tertiary)
                    }.font(.system(size: 11)).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                if model.previewVisible {
                    HStack(alignment: .top, spacing: 8) {
                        if model.mode.includesCamera {
                            LiveVideoPreview(feed: model.cameraPreview, title: "摄像头 · 话筒", symbol: "video", height: model.mode == .both ? 86 : 148, recording: model.canStop, busy: model.busy)
                        }
                        if model.mode.includesDesktop {
                            LiveVideoPreview(feed: model.desktopPreview, title: "桌面 · 系统声音", symbol: "display", height: model.mode == .both ? 86 : 148, recording: model.canStop, busy: model.busy)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    if model.canStop { model.stop() } else { model.start() }
                } label: {
                    Label(model.canStop ? "停止并保存" : "开始录制", systemImage: model.canStop ? "stop.fill" : "record.circle")
                        .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 3)
                }
                .disabled(model.busy && !model.canStop).buttonStyle(RecorderActionStyle(accent: accent))
                Button { model.reveal() } label: { Image(systemName: "folder").frame(width: 20, height: 20) }
                    .help("打开素材目录").accessibilityLabel("打开素材目录")
                Button { model.refreshDevices(); model.scanRecovery(); model.settingsVisible = true } label: {
                    Image(systemName: model.recoverable.isEmpty ? "slider.horizontal.3" : "exclamationmark.arrow.triangle.2.circlepath")
                        .frame(width: 20, height: 20)
                }.disabled(model.busy).help("设备、保存位置与素材恢复").accessibilityLabel("录制设置")
            }.controlSize(.regular)
        }
        .padding(16).frame(width: 336).fixedSize(horizontal: false, vertical: true)
        .background { ZStack { RecorderMaterial(); Color.black.opacity(0.56) } }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.10), lineWidth: 1).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(GeometryReader { geometry in
            Color.clear.onAppear { model.onResize?(geometry.size.height) }
                .onChange(of: geometry.size.height) { _, height in model.onResize?(height) }
        })
        .preferredColorScheme(.dark).ignoresSafeArea()
        .sheet(isPresented: $model.settingsVisible) { CaptureSettings(model: model).preferredColorScheme(.dark) }
        .onAppear { model.scanRecovery() }
        .alert("录制提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

private struct RecorderMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}


private struct RecorderActionStyle: ButtonStyle {
    let accent: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(accent.opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
