import Foundation
import Testing
@testable import BiliGlass

private final class UpdateProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  // All shared fixture state is accessed under lock.
  nonisolated(unsafe) static var requests: [URLRequest] = []
  nonisolated(unsafe) static var status = 200
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let status = Self.lock.withLock { Self.requests.append(request); return Self.status }
    let body = Data(#"{"tag_name":"v1.1.10","html_url":"https://github.com/wzk112/Bilibili-NEXT/releases/tag/v1.1.10","body":"notes","draft":false,"prerelease":false,"assets":[{"name":"Bilibili-NEXT-1.1.10-macOS-arm64.zip","browser_download_url":"https://github.com/wzk112/Bilibili-NEXT/releases/download/v1.1.10/Bilibili-NEXT-1.1.10-macOS-arm64.zip"}]}"#.utf8)
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct MacUpdateTests {
  @Test func versionsAndAssetSelectionDoNotDowngradeOrOfferOtherPlatform() throws {
    #expect(ReleaseVersion("1.1.10")! > ReleaseVersion("v1.1.4")!)
    #expect(ReleaseVersion("1.1.4") == ReleaseVersion("1.1.4.0"))
    #expect(ReleaseVersion("1.1.4-beta") == nil)
    #expect(!MacUpdater.validRepository("../../evil"))
    #expect(!AppRelease.trusted(URL(string:"https://github.com/other/repo/releases/download/v1/a.zip")!, repository:"wzk112/Bilibili-NEXT", releasesOnly:true))
  }
  @Test func checkingIsCookieFreeAndErrorsDoNotReportUpToDate() async throws {
    let suite = "update-tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [UpdateProtocol.self]
    config.httpCookieStorage = nil
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    UpdateProtocol.lock.withLock { UpdateProtocol.requests = []; UpdateProtocol.status = 200 }
    let updater = MacUpdater(defaults: defaults, session: session)
    updater.check(); updater.check()
    for _ in 0..<100 where updater.checking { try await Task.sleep(for: .milliseconds(10)) }
    #expect(updater.checked && updater.hasNewVersion && updater.error == nil)
    #expect(updater.downloadURL?.path.hasSuffix("macOS-arm64.zip") == true)
    let requests = UpdateProtocol.lock.withLock { UpdateProtocol.requests }
    #expect(requests.count == 1 && requests.first?.value(forHTTPHeaderField: "Cookie") == nil)
    updater.setAutomaticInstallation(true)
    #expect(!updater.automaticInstallation && !updater.canInstallAutomatically)
    UpdateProtocol.lock.withLock { UpdateProtocol.status = 403 }
    let failed = MacUpdater(defaults: defaults, session: session)
    failed.check()
    for _ in 0..<100 where failed.checking { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!failed.checked && failed.error != nil && !failed.hasNewVersion)
  }
}
