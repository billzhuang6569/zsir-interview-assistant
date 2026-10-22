import AppKit
import SwiftUI
import RecordingCore

struct UpdateVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ value: String, system: Bool = false) {
        let tokens = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (system ? (1...4).contains(tokens.count) : tokens.count == 3),
              tokens.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) && ($0.count == 1 || $0.first != "0") }),
              tokens.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = tokens.map { Int($0)! } + Array(repeating: 0, count: 4 - tokens.count)
    }
    static func < (a: Self, b: Self) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
}
struct UpdateManifest: Codable {
    let schemaVersion: Int
    let releases: [Release]
    struct Release: Codable {
        let version: String
        let summary: String
        let releaseURL: String
        let assets: [Asset]
        let withdrawn: Bool?
    }
    struct Asset: Codable {
        let os: String
        let arch: String
        let edition: String
        let minOS: String
        let url: String
        let sha256: String
        let size: Int64
    }
    func select(current: String, system: String, arch: String) throws -> (Release?, Asset?, Bool) {
        guard schemaVersion == 1, releases.count <= 100,
              let currentVersion = UpdateVersion(current), let os = UpdateVersion(system, system: true) else { throw UpdateFailure.invalid }
        var best: (Release, Asset)?
        var incompatible = false
        for release in releases {
            if release.withdrawn == true { continue }
            guard let version = UpdateVersion(release.version) else {
                let pieces = release.version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                if pieces.count == 2, UpdateVersion(String(pieces[0])) != nil,
                   !pieces[1].isEmpty, pieces[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) { continue }
                throw UpdateFailure.invalid
            }
            guard release.summary.count <= 4000, UpdateTransport.safeURL(release.releaseURL) != nil else { throw UpdateFailure.invalid }
            for asset in release.assets where asset.os == "macos" && asset.edition == "standard" && asset.arch == arch {
                guard let minimum = UpdateVersion(asset.minOS, system: true), UpdateTransport.safeURL(asset.url) != nil,
                      asset.size > 0, asset.sha256.count == 64, asset.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw UpdateFailure.invalid }
                if minimum > os { if version > currentVersion { incompatible = true }; continue }
                if version > currentVersion && (best == nil || version > UpdateVersion(best!.0.version)!) { best = (release, asset) }
            }
        }
        return (best?.0, best?.1, incompatible)
    }
}
enum UpdateFailure: LocalizedError {
    case invalid, tooLarge, http(Int), limited(Date)
    var errorDescription: String? {
        switch self {
        case .invalid: return "更新清单或地址无效"
        case .tooLarge: return "更新清单超过大小限制"
        case .http(let code): return "更新服务返回 HTTP \(code)，请稍后重试"
        case .limited(let date): return "更新服务限流，请在 \(date.formatted()) 后重试"
        }
    }
}
final class UpdateTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var redirects = 0
    static func safeURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else { return nil }
        return url
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        completionHandler(redirects <= 5 && Self.safeURL(request.url?.absoluteString ?? "") != nil ? request : nil)
    }
    func fetch(_ source: String, etag: String?, cached: Data?, session supplied: URLSession? = nil, retry304: Bool = true, deadline: Date = Date().addingTimeInterval(10)) async throws -> (Data, String?) {
        guard let url = Self.safeURL(source) else { throw UpdateFailure.invalid }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw URLError(.timedOut) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = remaining; config.timeoutIntervalForResource = remaining
        let session = supplied ?? URLSession(configuration: config)
        defer { if supplied == nil { session.invalidateAndCancel() } }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: remaining)
        request.setValue("ZSirCapture-Update/1", forHTTPHeaderField: "User-Agent")
        if cached != nil { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (bytes, rawResponse) = try await session.bytes(for: request, delegate: self)
        guard let response = rawResponse as? HTTPURLResponse else { throw UpdateFailure.invalid }
        if response.statusCode == 304 {
            if let cached { return (cached, etag) }
            if retry304 { return try await fetch(source, etag: nil, cached: nil, session: supplied, retry304: false, deadline: deadline) }
        }
        if response.statusCode == 429 || response.statusCode == 403 {
            let text = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let until = Double(text).map { Date().addingTimeInterval(max(60, $0)) } ?? formatter.date(from: text) ?? Date().addingTimeInterval(3600)
            throw UpdateFailure.limited(max(Date().addingTimeInterval(60), until))
        }
        guard response.statusCode == 200 else { throw UpdateFailure.http(response.statusCode) }
        guard response.expectedContentLength <= 262144 else { throw UpdateFailure.tooLarge }
        var data = Data()
        for try await byte in bytes { guard data.count < 262144 else { throw UpdateFailure.tooLarge }; data.append(byte) }
        return (data, response.value(forHTTPHeaderField: "ETag"))
    }
}

@MainActor final class Updates: ObservableObject {
    static let defaultSource = "https://github.com/billzhuang6569/zsir-interview-assistant/releases/latest/download/updates.json"
    let defaults: UserDefaults
    let version: String
    @Published var source: String
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: "updateAutomatic") } }
    @Published var status = "尚未检查"
    @Published var checking = false
    @Published var lastCheck: Date?
    @Published var release: UpdateManifest.Release?
    @Published var asset: UpdateManifest.Asset?
    var pendingPrompt = false
    var busy: () -> Bool = { false }
    private var reminded = Set<String>()
    private var timer: Timer?
    static var hostArch: String {
        var value: Int32 = 0; var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1 ? "arm64" : "x86_64"
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
        source = defaults.string(forKey: "updateSource") ?? Self.defaultSource
        automatic = defaults.object(forKey: "updateAutomatic") as? Bool ?? true
        lastCheck = defaults.object(forKey: "updateLastAttempt") as? Date
    }
    func start() {
        guard !RecordingCapabilities.macOS12Edition, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.check(manual: false) } }
        Task { await check(manual: false) }
    }
    func check(manual: Bool = true, newSource: String? = nil) async {
        guard !RecordingCapabilities.macOS12Edition, !checking, !busy() else { return }
        let candidate = newSource ?? source
        guard UpdateTransport.safeURL(candidate) != nil else { status = "请填写有效的 HTTPS 清单地址"; return }
        let changing = candidate != source
        if !changing, let retry = defaults.object(forKey: "updateRetryAfter") as? Date, retry > Date() {
            if manual { status = UpdateFailure.limited(retry).localizedDescription }; return
        }
        if !manual && (!automatic || (lastCheck.map { Date().timeIntervalSince($0) < 86400 } ?? false)) { return }
        checking = true; status = "正在检查…"
        defer { checking = false }
        if !changing { lastCheck = Date(); defaults.set(lastCheck, forKey: "updateLastAttempt") }
        do {
            let (data, tag) = try await UpdateTransport().fetch(candidate, etag: changing ? nil : defaults.string(forKey: "updateETag"), cached: changing ? nil : defaults.data(forKey: "updateCache"))
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let selection = try manifest.select(current: version, system: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", arch: Self.hostArch)
            if changing {
                for key in ["updateIgnored", "updateETag", "updateCache", "updateRetryAfter"] { defaults.removeObject(forKey: key) }
                reminded.removeAll(); pendingPrompt = false; source = candidate; defaults.set(source, forKey: "updateSource")
                lastCheck = Date(); defaults.set(lastCheck, forKey: "updateLastAttempt")
            }
            defaults.set(data, forKey: "updateCache"); defaults.set(tag, forKey: "updateETag"); defaults.removeObject(forKey: "updateRetryAfter")
            pendingPrompt = false; release = selection.0; asset = selection.1
            status = release.map { "发现新版本 \($0.version)" } ?? (selection.2 ? "当前系统无可用更新；更高版本需要升级系统" : "未发现适用于此系统和架构的新版本")
            if !manual, let release, defaults.string(forKey: "updateIgnored") != release.version, !reminded.contains(release.version) { pendingPrompt = true }
        } catch {
            if !changing, case UpdateFailure.limited(let until) = error { defaults.set(until, forKey: "updateRetryAfter") }
            if !changing, error is DecodingError || (error as? UpdateFailure).map({ if case .invalid = $0 { return true }; return false }) == true {
                defaults.removeObject(forKey: "updateCache"); defaults.removeObject(forKey: "updateETag")
            }
            release = nil; asset = nil; pendingPrompt = false
            status = "检查失败：\(error.localizedDescription)" + (changing ? "；仍保留原更新来源" : "")
        }
    }
    func download() {
        guard !busy(), let asset, let url = UpdateTransport.safeURL(asset.url) else { return }
        NSWorkspace.shared.open(url)
    }
    func promptIfNeeded(window: NSWindow) {
        guard automatic, pendingPrompt, !busy(), window.attachedSheet == nil, let release else { return }
        pendingPrompt = false; reminded.insert(release.version)
        let alert = NSAlert(); alert.messageText = "发现新版本 \(release.version)"
        alert.informativeText = release.summary + "\n系统要求：macOS \(asset?.minOS ?? "13.0") 或以上。\n下载后请先停止保存并退出，再替换应用。"
        alert.addButton(withTitle: "下载新版"); alert.addButton(withTitle: "稍后"); alert.addButton(withTitle: "忽略此版本")
        alert.beginSheetModal(for: window) { [weak self] result in
            Task { @MainActor in
                if result == .alertFirstButtonReturn { self?.download() }
                if result == .alertThirdButtonReturn { self?.defaults.set(release.version, forKey: "updateIgnored") }
            }
        }
    }
}
struct UpdateSettings: View {
    @ObservedObject var updates: Updates
    @State private var address = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("版本与更新").font(.headline)
            Text("当前版本 \(updates.version)")
            Toggle("自动检查更新", isOn: $updates.automatic)
            HStack { Text(updates.status).font(.caption); Spacer(); Button("检查更新") { Task { await updates.check() } }.disabled(updates.checking) }
            if let date = updates.lastCheck { Text("上次检查：\(date.formatted())").font(.caption).foregroundStyle(.secondary) }
            if let release = updates.release {
                Text(release.summary).font(.caption)
                if let asset = updates.asset { Text("系统要求：macOS \(asset.minOS) 或以上").font(.caption).foregroundStyle(.secondary) }
                Button("下载 \(release.version)") { updates.download() }
                Text("下载后停止并保存、退出应用，再替换旧版。").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("更新来源") {
                TextField("HTTPS 清单地址", text: $address)
                HStack {
                    Button("验证并使用") { Task { await updates.check(newSource: address) } }
                    Button("恢复 GitHub") { address = Updates.defaultSource; Task { await updates.check(newSource: address) } }
                }.disabled(updates.checking)
                Text("当前：\(updates.source)").font(.caption).textSelection(.enabled)
                Text("仅检查版本，不上传素材；自定义来源失败不会切换到其他服务器。").font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { address = updates.source }
    }
}
