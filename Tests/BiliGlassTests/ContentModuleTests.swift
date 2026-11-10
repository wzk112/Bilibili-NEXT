import AVFoundation
import BiliPlayback
import Foundation
import Testing
@testable import BiliGlass

private final class CatalogProtocol: URLProtocol, @unchecked Sendable {
  static let lock = NSLock()
  // All shared fixture state is accessed under lock.
  nonisolated(unsafe) static var requests: [URLRequest] = []
  private let stateLock = NSLock()
  private var stopped = false
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  static func clear() { lock.withLock { requests = [] } }
  static func snapshot() -> [URLRequest] { lock.withLock { requests } }
  override func startLoading() {
    var recorded = request
    if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
      stream.open(); defer { stream.close() }
      var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
      }
      recorded.httpBody = data
    }
    Self.lock.withLock { Self.requests.append(recorded) }
    let url = request.url!
    let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name,$0.value ?? "") }, uniquingKeysWith: { a,_ in a })
    var root: [String: Any] = ["code": 0, "data": [:]]
    var delay = 0.0
    if url.path == "/pgc/season/index/result" {
      let type = Int(query["season_type"] ?? "1") ?? 1
      let page = Int(query["page"] ?? "1") ?? 1
      let ids = page == 1 ? [type * 10, type * 10 + 1] : [type * 10 + 1, type * 10 + 2]
      root["data"] = ["list": ids.map { ["season_id": $0, "title": "season \($0)", "cover": ""] }, "has_next": page == 1 ? 1 : 0]
      delay = type == 1 ? 0.1 : 0
    } else if url.path == "/pgc/player/web/playurl" {
      root = ["code": -10403, "message": "fixture permission denied"]
    }
    let body = try! JSONSerialization.data(withJSONObject: root)
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
      guard !stateLock.withLock({ stopped }) else { return }
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() { stateLock.withLock { stopped = true } }
}

@Suite(.serialized) @MainActor struct ContentModuleTests {
  private func api() -> API {
    CatalogProtocol.clear()
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CatalogProtocol.self]
    return API(loadCredentials: false, transport: URLSession(configuration: config))
  }
  @Test func disabledLiveFeatureNeverRequestsRoomSearchMetadataOrStreams() async throws {
    let api = api()
    defer { api.session.invalidateAndCancel() }
    #expect(!LiveAvailability.enabled)
    await #expect(throws: (any Error).self) { try await api.liveRooms() }
    await #expect(throws: (any Error).self) { try await api.liveRooms(keyword: "fixture") }
    await #expect(throws: (any Error).self) { try await api.liveRoom(1) }
    await #expect(throws: (any Error).self) { try await api.liveStream(roomID: 1) }
    let catalog = LiveCatalogModel()
    await catalog.load(api: api)
    await catalog.refresh(api: api)
    #expect(catalog.rooms.isEmpty && !catalog.loading)
    let playback = LivePlayback()
    let room = try #require(LiveRoom(["roomid": 1, "live_status": 1]))
    playback.open(room, api: api)
    #expect(playback.error == LiveAvailability.message && !playback.loading)
    #expect(playback.player.currentItem == nil)
    #expect(CatalogProtocol.snapshot().isEmpty)
  }
  @Test func changingCatalogIgnoresLateResponseAndPaginationDeduplicates() async throws {
    let api = api(); defer { api.session.invalidateAndCancel() }
    let model = SeasonCatalogModel()
    let old = Task { await model.load(api: api, type: 1, followed: false, keyword: "") }
    for _ in 0..<100 where CatalogProtocol.snapshot().isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    await model.load(api: api, type: 2, followed: false, keyword: "")
    await old.value
    #expect(model.items.map(\.id) == [20,21])
    await model.load(api: api, type: 2, followed: false, keyword: "", more: true)
    #expect(model.items.map(\.id) == [20,21,22] && !model.hasMore)
    await model.refresh(api: api)
    #expect(model.items.map(\.id) == [20,21])
  }
  @Test func episodePlaybackAndQualityRetryUsePGCInterface() async throws {
    let api = api(); let playback = Playback()
    defer { playback.stop(); api.session.invalidateAndCancel() }
    let season = try SeasonDetail(["season_id": 1, "title": "series", "episodes": [["id": 11,"bvid":"BV1xx411c7mD","aid":10,"cid":20,"title":"1","duration":120000]]])
    let episode = try #require(season.episodes.first)
    playback.openEpisode(episode, season: season, api: api, resume: .init(position: 5, playing: false))
    for _ in 0..<100 where playback.loading { try await Task.sleep(for: .milliseconds(10)) }
    #expect(playback.currentEpisodeID == 11 && playback.currentSeasonID == 1)
    #expect(playback.error != nil)
    playback.selectQuality(64, api: api, force: true)
    for _ in 0..<100 where playback.loading { try await Task.sleep(for: .milliseconds(10)) }
    let paths = CatalogProtocol.snapshot().map { $0.url!.path }
    #expect(paths.count == 2 && paths.allSatisfy { $0 == "/pgc/player/web/playurl" })
    #expect(playback.pendingResume?.playing == false)
    playback.stop()
    #expect(playback.currentEpisodeID == nil && playback.currentSeasonID == nil)
  }
  @Test func followUsesAuthenticatedCSRFPostAndGuestDoesNotWrite() async throws {
    let api = api(); defer { api.session.invalidateAndCancel() }
    await #expect(throws: (any Error).self) { try await api.followSeason(9, following: true) }
    #expect(CatalogProtocol.snapshot().isEmpty)
    api.cookies = ["SESSDATA":"fixture-session","bili_jct":"fixture-csrf","DedeUserID":"7"]
    try await api.followSeason(9, following: true)
    try await api.followSeason(9, following: false)
    let requests = CatalogProtocol.snapshot()
    #expect(requests.map { $0.url!.path } == ["/pgc/web/follow/add","/pgc/web/follow/del"])
    #expect(requests.allSatisfy { $0.httpMethod == "POST" && String(data: $0.httpBody ?? Data(), encoding: .utf8)?.contains("csrf=fixture-csrf") == true })
  }
  @Test func episodeHistoryRoundTripRetainsSeasonAndEpisode() throws {
    let video = Video(bvid: "BV1xx411c7mD", title: "episode", cover: "", author: "", duration: 120, views: 0)
    let history = HistoryEntry(video: video, positions: ["20":15], date: .now, lastCID: 20, accountID: "guest", episodeID: 11, seasonID: 1)
    let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(history))
    let merged = AccountHistoryEntry.merged(remote: [], local: [decoded], accountID: "guest")
    #expect(merged.first?.episodeID == 11 && merged.first?.seasonID == 1 && merged.first?.progress == 15)
  }
  @Test func liveURLsAndPlaylistsPreserveRelativeResourcesAndRejectForeignHosts() throws {
    #expect(LiveRoom.roomID("https://live.bilibili.com/123?foo=1") == 123)
    #expect(LiveRoom.roomID("https://live.bilibili.com.evil.example/123") == nil)
    #expect(LiveRoom.roomID("https://live.bilibili.com/blanc/123") == 123)
    let base = URL(string: "https://live-play.bilivideo.com/live-bvc/playlist.m3u8?fixture=1")!
    var remotes: [URL] = []
    let output = try LiveHLSRelay.rewrite("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2,\n1.m4s\n", base: base) { url in
      remotes.append(url); return "http://127.0.0.1:1234/token/\(remotes.count)"
    }
    #expect(remotes.map(\.path) == ["/live-bvc/init.mp4","/live-bvc/1.m4s"])
    #expect(output.contains("URI=\"http://127.0.0.1:1234/token/1\""))
    #expect(throws: (any Error).self) { try LiveHLSRelay.rewrite("#EXTM3U\nhttp://127.0.0.1/private\n", base: base) { $0.absoluteString } }
    #expect(throws: (any Error).self) { try LiveStream.parse(["playurl_info":["playurl":["stream":[]]]]) }
  }
  @Test func continuationQueueDoesNotAppendTrailersToMainEpisodes() throws {
    let season = try SeasonDetail(["season_id": 1, "episodes": [["id":1,"title":"1"],["id":2,"title":"2"]],
      "section": [["title":"预告", "episodes":[["id":3,"title":"PV"],["id":1,"title":"duplicate"]]]]])
    #expect(season.episodes.map(\.id) == [1,2,3])
    #expect(season.episodeGroups.map(\.title) == ["正片","预告"])
    #expect(season.queue(for: season.episodes[0]).map(\.id) == [1,2])
    #expect(season.queue(for: season.episodes[2]).map(\.id) == [3])
  }
}
