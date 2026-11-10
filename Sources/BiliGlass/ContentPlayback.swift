import SwiftUI

extension Store {
  func openEpisode(_ episode: SeasonEpisode, season: SeasonDetail, present: Bool = true, continuing: Bool = false, position: Double? = nil) {
    guard episode.cid > 0, !episode.bvid.isEmpty else { interactionMessage = "这一集暂时没有可播放的视频"; return }
    guard !episode.areaLimited else { interactionMessage = "这一集在当前地区暂不可播放"; return }
    livePlayback.stop(); activeLiveRoom = nil
    isPlaybackOpen = true; seasonPlayback = season
    playQueue = season.queue(for: episode).filter { $0.cid > 0 && !$0.bvid.isEmpty }.map {
      PlaybackQueueItem(bvid: $0.bvid, cid: $0.cid, title: $0.title)
    }
    queueTitle = season.title
    extras.reset(); videoActions.clear(); comments.stop(); danmaku.stop()
    if present { navigationRevision += 1; profileTarget = nil; showPlayer = true; playerFocus += 1 }
    playback.openEpisode(episode, season: season, api: api,
      resume: PlaybackResume(position: position ?? (continuing ? 0 : self.position(episode.bvid, cid: episode.cid)),
        playing: continuing || (UserDefaults.standard.object(forKey: "autoPlay") as? Bool ?? true)))
    playback.focusPlayer()
  }
  func restoreEpisode(seasonID: Int, episodeID: Int, position: Double) {
    navigationRevision += 1
    let token = navigationRevision
    Task {
      do {
        let season = try await api.season(id: seasonID)
        guard token == navigationRevision else { return }
        guard let episode = season.episodes.first(where: { $0.id == episodeID }) else { throw BiliError(text: "这一集已不可用") }
        openEpisode(episode, season: season, position: position)
      } catch { if token == navigationRevision { interactionMessage = error.localizedDescription } }
    }
  }
  func openLocalHistory(_ entry: HistoryEntry) {
    if let seasonID = entry.seasonID, let episodeID = entry.episodeID {
      restoreEpisode(seasonID: seasonID, episodeID: episodeID, position: entry.positions["\(entry.lastCID ?? 0)"] ?? 0)
    } else { open(entry.video.bvid, initialCID: entry.lastCID) }
  }
  func openLive(_ room: LiveRoom) {
    guard LiveAvailability.enabled else { navigate(.live); return }
    playback.stop(); isPlaybackOpen = false; showPlayer = false; seasonPlayback = nil
    comments.stop(); danmaku.stop(); extras.reset(); videoActions.clear()
    activeLiveRoom = room
  }
}

@MainActor @Observable final class SeasonCatalogModel {
  var items: [SeasonSummary] = []
  var loading = false
  var error: String?
  var hasMore = false
  let position = BrowsePosition()
  private var key = ""
  private var page = 0
  private var generation = UUID()
  private var configuration: (type: Int, followed: Bool, keyword: String)?
  func reset() { generation = UUID(); key = ""; items = []; page = 0; loading = false; hasMore = false; error = nil; position.reset() }
  func load(api: API, type: Int, followed: Bool, keyword: String, refresh: Bool = false, more: Bool = false) async {
    let nextKey = "\(type):\(followed):\(keyword):\(api.authenticationGeneration)"
    if refresh || key != nextKey { reset(); key = nextKey }
    configuration = (type, followed, keyword)
    guard !loading, (more ? hasMore : page == 0) else { return }
    let request = generation
    let nextPage = page + 1
    loading = true; error = nil
    do {
      let result: ([SeasonSummary], Bool)
      if followed { result = try await api.followedSeasons(type: type, page: nextPage) }
      else { result = try await api.catalog(type: type, page: nextPage, keyword: keyword) }
      let (rows, next) = result
      try Task.checkCancellation()
      guard request == generation else { return }
      var seen = Set(items.map(\.id))
      items += rows.filter { seen.insert($0.id).inserted }
      page = nextPage; hasMore = next; loading = false
    } catch {
      guard request == generation else { return }
      loading = false
      if !(error is CancellationError) { self.error = error.localizedDescription }
    }
  }
  func refresh(api: API) async {
    guard let configuration else { return }
    await load(api: api, type: configuration.type, followed: configuration.followed, keyword: configuration.keyword, refresh: true)
  }
}

@MainActor @Observable final class LiveCatalogModel {
  var rooms: [LiveRoom] = []
  var loading = false
  var error: String?
  let position = BrowsePosition()
  private var generation = UUID()
  private var loaded = false
  private var lastKeyword = ""
  func load(api: API, keyword: String = "", refresh: Bool = false) async {
    guard LiveAvailability.enabled else { rooms = []; loading = false; error = nil; return }
    if loaded && !refresh { return }
    generation = UUID(); let request = generation
    lastKeyword = keyword
    loading = true; error = nil; position.reset()
    do {
      let rows = try await api.liveRooms(keyword: keyword)
      try Task.checkCancellation()
      guard request == generation else { return }
      rooms = rows; loading = false; loaded = true
    } catch {
      guard request == generation else { return }
      loading = false
      if !(error is CancellationError) { self.error = error.localizedDescription }
    }
  }
  func refresh(api: API) async { await load(api: api, keyword: lastKeyword, refresh: true) }
}
