import RecordingCore
import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class LivePreviewFeed: ObservableObject {
    @Published var frame: (sample: CMSampleBuffer, capturedAt: Date)?
}

struct LiveVideoPreview: View {
    @ObservedObject var feed: LivePreviewFeed
    let title: String
    let symbol: String
    let height: CGFloat
    let recording: Bool
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28))
                if let frame = feed.frame {
                    VideoSurface(sample: frame.sample)
                        .accessibilityLabel("\(title)\(recording ? "实时视频" : "最后画面")")
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: symbol).font(.system(size: 20, weight: .light))
                        Text(busy ? "等待录制画面" : "开始后显示画面").font(.system(size: 10))
                    }.foregroundStyle(.white.opacity(0.45))
                }
            }.frame(height: height).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.06), lineWidth: 1))
            if let frame = feed.frame {
                Text("\(recording ? "最近画面" : "最后画面") \(frame.capturedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(" ").font(.system(size: 9)).accessibilityHidden(true)
            }
        }.frame(maxWidth: .infinity)
    }
}

struct VideoSurface: NSViewRepresentable {
    let sample: CMSampleBuffer

    func makeNSView(context: Context) -> VideoSurfaceView { VideoSurfaceView() }
    func updateNSView(_ view: VideoSurfaceView, context: Context) { view.display(sample) }
}

final class VideoSurfaceView: NSView {
    private let videoLayer = AVSampleBufferDisplayLayer()
    private var lastSample: CMSampleBuffer?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer = videoLayer
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func display(_ sample: CMSampleBuffer) {
        guard lastSample !== sample else { return }
        // A slow preview drops frames instead of building latency or blocking capture.
        if #available(macOS 14, *), !RecordingCapabilities.macOS12Edition {
            let renderer = videoLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            guard renderer.isReadyForMoreMediaData else { return }
            renderer.enqueue(sample)
        } else {
            if videoLayer.status == .failed { videoLayer.flush() }
            guard videoLayer.isReadyForMoreMediaData else { return }
            videoLayer.enqueue(sample)
        }
        lastSample = sample
    }
}
