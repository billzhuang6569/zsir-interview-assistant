import Foundation

private final class UpdateMock: URLProtocol, @unchecked Sendable {
    static var code = 200
    static var payload = Data()
    static var headers: [String: String] = [:]
    static var requests = 0
    static var failure: URLError?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        if let failure = Self.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor enum UpdateChecks {
    static func run() async throws {
        precondition(UpdateVersion("0.10.0")! > UpdateVersion("0.9.0")!)
        for invalid in ["1", "1.2", "1.2.3-preview.1", "01.2.3", "1.2.-3", "1.2.٣", "1.2.999999999999999999999999"] { precondition(UpdateVersion(invalid) == nil) }
        for invalid in ["http://example.com/a", "file:///tmp/a", "https://u:p@example.com/a", "javascript:alert(1)", "https://example.com/a#f"] { precondition(UpdateTransport.safeURL(invalid) == nil) }
        let hash = String(repeating: "a", count: 64)
        func asset(_ arch: String = "arm64", _ edition: String = "standard", _ min: String = "13.0") -> UpdateManifest.Asset {
            .init(os: "macos", arch: arch, edition: edition, minOS: min, url: "https://example.com/app.zip", sha256: hash, size: 100)
        }
        func release(_ v: String, _ assets: [UpdateManifest.Asset], withdrawn: Bool = false) -> UpdateManifest.Release {
            .init(version: v, summary: "测试", releaseURL: "https://example.com/release", assets: assets, withdrawn: withdrawn)
        }
        let manifest = UpdateManifest(schemaVersion: 1, releases: [release("0.4.0", [asset()]), release("0.5.0", [asset("arm64", "standard", "15.0")]), release("1.0.0", [asset("arm64", "monterey", "12.3")]), release("2.0.0-preview.1", [asset()]), release("3.0.0", [asset()], withdrawn: true)])
        let selection = try manifest.select(current: "0.3.0", system: "13.0", arch: "arm64")
        precondition(selection.0?.version == "0.4.0" && selection.2)
        let equal = try manifest.select(current: "0.4.0", system: "13.0", arch: "arm64"); precondition(equal.0 == nil)
        let absent = try manifest.select(current: "0.3.0", system: "13.0", arch: "x86_64"); precondition(absent.0 == nil)
        let older = try manifest.select(current: "5.0.0", system: "15.0", arch: "arm64"); precondition(older.0 == nil)
        do { _ = try UpdateManifest(schemaVersion: 1, releases: [release("garbage", [asset()])]).select(current: "0.3.0", system: "13.0", arch: "arm64"); preconditionFailure("Bad release version accepted") }
        catch UpdateFailure.invalid {}
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UpdateMock.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        UpdateMock.payload = try JSONEncoder().encode(manifest); UpdateMock.headers = ["ETag": "test-v1"]
        let source = "https://example.com/updates.json"
        let fetched = try await UpdateTransport().fetch(source, etag: nil, cached: nil, session: session)
        precondition(fetched.0 == UpdateMock.payload && fetched.1 == "test-v1")
        UpdateMock.code = 304
        let cached = try await UpdateTransport().fetch(source, etag: "test-v1", cached: fetched.0, session: session)
        precondition(cached.0 == fetched.0)
        UpdateMock.requests = 0
        do { _ = try await UpdateTransport().fetch(source, etag: nil, cached: nil, session: session); preconditionFailure("304 without cache accepted") }
        catch { precondition(UpdateMock.requests == 2) }
        for code in [403, 429] {
            UpdateMock.code = code; UpdateMock.headers = ["Retry-After": "120"]
            do { _ = try await UpdateTransport().fetch(source, etag: nil, cached: nil, session: session); preconditionFailure("rate limit accepted") }
            catch UpdateFailure.limited(let until) { precondition(until.timeIntervalSinceNow > 100) }
        }
        UpdateMock.code = 200; UpdateMock.headers = [:]; UpdateMock.payload = Data(repeating: 65, count: 262145)
        do { _ = try await UpdateTransport().fetch(source, etag: nil, cached: nil, session: session); preconditionFailure("oversize accepted") }
        catch UpdateFailure.tooLarge {}
        for payload in [Data("{".utf8), Data("{\"schemaVersion\":2,\"releases\":[]}".utf8)] {
            do {
                let decoded = try JSONDecoder().decode(UpdateManifest.self, from: payload)
                _ = try decoded.select(current: "0.3.0", system: "13.0", arch: "arm64")
                preconditionFailure("Invalid manifest accepted")
            } catch {}
        }
        UpdateMock.code = 500; UpdateMock.payload = Data()
        do { _ = try await UpdateTransport().fetch(source, etag: nil, cached: nil, session: session); preconditionFailure("HTTP failure accepted") }
        catch UpdateFailure.http(500) {}
        UpdateMock.failure = URLError(.notConnectedToInternet)
        do { _ = try await UpdateTransport().fetch(source, etag: nil, cached: nil, session: session); preconditionFailure("Offline reported as success") }
        catch let error as URLError { precondition(error.code == .notConnectedToInternet) }
        UpdateMock.failure = nil
        do { _ = try await UpdateTransport().fetch(source, etag: nil, cached: nil, session: session, deadline: .distantPast); preconditionFailure("Expired deadline accepted") }
        catch let error as URLError { precondition(error.code == .timedOut) }
        let defaults = UserDefaults(suiteName: "update-checks-\(UUID())")!
        let service = Updates(defaults: defaults); service.busy = { true }
        await service.check(); precondition(service.lastCheck == nil && !service.checking)
        service.busy = { false }; service.automatic = false
        await service.check(manual: false); precondition(service.lastCheck == nil)
        let previous = service.source
        await service.check(newSource: "http://unsafe.example/updates.json")
        precondition(service.source == previous)
        defaults.removeObject(forKey: "updateAutomatic")
        print("PASS updates: version/edition/architecture/compatibility, HTTPS, 200/304/cache, 403/429, size limit, busy/disabled/source safety")
    }
}
