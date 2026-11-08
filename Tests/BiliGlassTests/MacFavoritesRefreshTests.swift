import AppKit
import SwiftUI
import Synchronization
import Testing
@testable import BiliGlass

private final class FavoritesRefreshProtocol: URLProtocol, @unchecked Sendable {
  static let requests = Mutex<[Int]>([])
  private var work: DispatchWorkItem?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let folder = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
      .first(where: { $0.name == "media_id" })?.value.flatMap(Int.init)
    let body: [String: Any]
    if let folder {
      Self.requests.withLock { $0.append(folder) }
      body = ["code": 0, "data": ["medias": [["bvid": "BV-folder-\(folder)", "title": "folder \(folder)",
        "duration": 60, "upper": ["name": "fixture"]]]]]
    } else if request.url?.path == "/x/web-interface/nav" {
      body = ["code": 0, "data": ["isLogin": true, "mid": 42, "uname": "fixture"]]
    } else { body = ["code": 0, "data": [:]] }
    let bytes = try! JSONSerialization.data(withJSONObject: body)
    let task = DispatchWorkItem { [self] in
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
        httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: bytes)
      client?.urlProtocolDidFinishLoading(self)
    }
    work = task
    DispatchQueue.main.asyncAfter(deadline: .now() + (folder == 2 ? 0.3 : 0.01), execute: task)
  }
  override func stopLoading() { work?.cancel() }
}

@MainActor @Suite(.serialized) struct MacFavoritesRefreshTests {
  private func wait(_ label: String, store: Store, _ condition: () -> Bool) async throws {
    for _ in 0..<250 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition(), Comment(rawValue: "\(label): selected=\(store.selectedFolder), first=\(store.videos.first?.bvid ?? "none"), busy=\(store.busy), requests=\(FavoritesRefreshProtocol.requests.withLock { $0 })"))
  }

  @Test func actualMacPickerObserverReloadsAndRapidFolderChangesKeepLatestResults() async throws {
    _ = NSApplication.shared
    FavoritesRefreshProtocol.requests.withLock { $0.removeAll() }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FavoritesRefreshProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: config),
      credentialAccount: "mac-favorites-fixture-" + UUID().uuidString)
    let store = Store(api: api)
    store.destination = .favorites
    store.account = Account(name: "fixture", mid: 42, face: "")
    store.restoring = false
    store.folders = [FavoriteFolder(id: 1, title: "one", count: 1), FavoriteFolder(id: 2, title: "two", count: 1)]
    store.selectedFolder = 1
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 840),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: RootView(store: store))
    window.orderBack(nil)
    defer {
      store.navigate(.web); window.orderOut(nil); window.contentView = nil
      api.session.invalidateAndCancel()
    }
    try await wait("initial", store: store) { !store.busy && store.videos.first?.bvid == "BV-folder-1" }
    store.selectedFolder = 2
    try await wait("switch-two", store: store) { !store.busy && store.videos.first?.bvid == "BV-folder-2" }
    store.selectedFolder = 1
    try await wait("switch-back", store: store) { !store.busy && store.videos.first?.bvid == "BV-folder-1" }
    store.selectedFolder = 2
    try await wait("race-start", store: store) { store.busy && FavoritesRefreshProtocol.requests.withLock { $0.filter { $0 == 2 }.count >= 2 } }
    store.selectedFolder = 1
    try await wait("race-end", store: store) { !store.busy && store.videos.first?.bvid == "BV-folder-1" }
    try await Task.sleep(for: .milliseconds(400))
    #expect(store.selectedFolder == 1)
    #expect(store.videos.first?.bvid == "BV-folder-1")
    #expect(store.error == nil)
  }
}
