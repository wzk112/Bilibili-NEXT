import Foundation
import Testing
@testable import BiliGlass

private final class CatalogProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.path
    let root: [String: Any]
    if path == "/pgc/view/web/season" {
      root = ["code": 0, "result": ["season_id": 42, "title": "测试剧集", "evaluate": "简介",
        "episodes": [["id": 77, "bvid": "BV1xx411c7mD", "cid": 100, "aid": 200,
          "title": "1", "long_title": "第一集", "duration": 90000]]]]
    } else if path == "/pgc/player/web/playurl" {
      root = ["code": -10403, "message": "当前地区不可播放"]
    } else if path == "/xlive/web-interface/v1/webMain/getMoreRecList", request.url?.host == "api.live.bilibili.com" {
      root = ["code": 0, "data": ["recommend_room_list": [["roomid": 6, "title": "直播", "uname": "主播"]]]]
    } else {
      root = ["code": -404, "message": "Unexpected request"]
    }
    let data = try! JSONSerialization.data(withJSONObject: root)
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private actor CatalogGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var waiting = false
  func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
  func release() { continuation?.resume(); continuation = nil }
}

@Suite @MainActor struct CatalogTests {
  private func item(_ id: Int) -> CatalogItem { .init(id: id, title: "条目", cover: "", subtitle: "", badge: "") }
  private func api(_ defaults: UserDefaults) -> API {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CatalogProtocol.self]
    return API(loadCredentials: false, transport: URLSession(configuration: config), catalogDefaults: defaults)
  }

  @Test func episodeMetadataSurvivesRelaunchAndKeepsPGCPermissions() async throws {
    let name = "catalog-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let first = api(defaults)
    defer { first.session.invalidateAndCancel() }
    let season = try await first.catalogSeason(42)
    #expect(season.episodes.first?.video.episodeID == 77)
    #expect(season.episodes.first?.video.duration == 90)
    let second = api(defaults)
    defer { second.session.invalidateAndCancel() }
    let detail = try await second.detail("BV1xx411c7mD")
    #expect(detail.video.title == "测试剧集 · 1 · 第一集")
    #expect(detail.pages.first?.id == 100)
    #expect(detail.collection?.items.first?.bvid == detail.video.bvid)
    do {
      _ = try await second.streams(bvid: detail.video.bvid, cid: 100)
      Issue.record("Restricted PGC playback must surface the server error")
    } catch let error as BiliError { #expect(error.code == -10403) }
  }

  @Test func liveRecommendationsUseTheLiveHostAndResponseShape() async throws {
    let name = "catalog-live-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let api = api(defaults); defer { api.session.invalidateAndCancel() }
    let items = try await api.catalog(.live, genre: 0, page: 1, followed: false, mid: nil)
    #expect(items.count == 1)
    #expect(items.first?.id == 6 && items.first?.subtitle == "主播")
  }

  @Test func staleCategoryRequestCannotOverwriteNewCategory() async {
    let model = CatalogModel(), gate = CatalogGate()
    let old = Task { await model.load(reset: true) { _ in await gate.wait(); return [item(1)] } }
    while !(await gate.waiting) { await Task.yield() }
    await model.load(reset: true) { _ in [item(2)] }
    await gate.release(); await old.value
    #expect(model.items.map(\.id) == [2])
    #expect(!model.loading && model.error == nil)
  }

  @Test func paginationDeduplicatesAndRetriesTheFailedPage() async {
    let model = CatalogModel()
    await model.load { _ in [item(1), item(1)] }
    #expect(model.items.count == 1)
    await model.load { page in #expect(page == 2); throw URLError(.timedOut) }
    #expect(model.error != nil && model.hasMore)
    await model.load { page in #expect(page == 2); return [item(1), item(2)] }
    #expect(model.items.map(\.id) == [1, 2])
    await model.load { _ in [item(2)] }
    #expect(!model.hasMore)
  }

  @Test func seasonFiltersInvalidAndDuplicateEpisodes() throws {
    let row: [String: Any] = ["id": 1, "bvid": "BV1xx411c7mD", "cid": 10, "duration": 120000]
    let season = try CatalogSeason.parse(["season_id": 1, "episodes": [row, row, ["id": 2]],
      "section": [["episodes": [row]]]])
    #expect(season.episodes.count == 1)
    #expect(season.episodes.first?.video.duration == 120)
  }

  @Test func livePlaybackSelectsHLSAndValidatesEveryCDNCandidate() throws {
    func play(_ sources: [[String: String]], protocolName: String = "http_hls") -> [String: Any] {
      ["stream": [["protocol_name": protocolName, "format": [["codec": [["codec_name": "avc",
        "base_url": "/live/playlist.m3u8", "url_info": sources]]]]]]]
    }
    let bad = ["host": "https://bilivideo.com.attacker.test", "extra": "?secret=fixture"]
    let good = ["host": "https://live.bilivideo.com", "extra": "?token=fixture"]
    #expect(try API.liveHLSURL(play([bad, good])).host == "live.bilivideo.com")
    #expect(throws: (any Error).self) { try API.liveHLSURL(play([bad])) }
    #expect(throws: (any Error).self) { try API.liveHLSURL(play([good], protocolName: "http_stream")) }
    #expect(throws: (any Error).self) { try API.liveHLSURL(play([["host": "https://127.0.0.1", "extra": ""]])) }
  }

  @Test(arguments: [125, 126], [1, 6, 7, 13, 14, 15])
  func explicitSDRMetadataOverridesTheQualityNumber(quality: Int, transfer: Int) {
    #expect(API.dynamicRange(["id": quality, "color_transfer": transfer]) == .sdr)
    #expect(API.dynamicRange(["id": quality, "color_transfer": 16]) == .pq)
    #expect(API.dynamicRange(["id": quality, "color_transfer": 18]) == .hlg)
  }
}
