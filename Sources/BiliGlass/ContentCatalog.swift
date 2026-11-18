import AVKit
import BiliNetworking
import SwiftUI

enum CatalogKind: String, CaseIterable, Identifiable {
  case live = "直播", bangumi = "追番", cinema = "影视"
  var id: String { rawValue }
  var symbol: String { self == .live ? "dot.radiowaves.left.and.right" : self == .bangumi ? "sparkles.tv" : "film" }
  var page: StartPage { self == .live ? .live : self == .bangumi ? .bangumi : .cinema }
  var website: URL {
    URL(string: self == .live ? "https://live.bilibili.com" : self == .bangumi
      ? "https://www.bilibili.com/anime/" : "https://www.bilibili.com/movie/")!
  }
}

struct CatalogItem: Identifiable, Equatable {
  let id: Int
  let title: String
  let cover: String
  let subtitle: String
  let badge: String
  static func parse(_ row: [String: Any], live: Bool) -> Self? {
    guard let id = row[live ? "roomid" : "season_id"] as? Int ?? row["room_id"] as? Int, id > 0 else { return nil }
    return .init(id: id, title: cleanTitle(row["title"] as? String ?? ""),
      cover: row["cover"] as? String ?? row["user_cover"] as? String ?? row["keyframe"] as? String ?? "",
      subtitle: live ? row["uname"] as? String ?? "" : row["index_show"] as? String ?? "",
      badge: live ? row["area_v2_name"] as? String ?? row["area_name"] as? String ?? "直播中" : row["badge"] as? String ?? "")
  }
}

struct CatalogEpisode: Identifiable {
  let id: Int
  let video: Video
  let cid: Int
  let title: String
  static func parse(_ row: [String: Any], season: String, cover: String) -> Self? {
    guard let id = row["id"] as? Int, id > 0, let cid = row["cid"] as? Int, cid > 0,
      let bvid = row["bvid"] as? String, videoID(bvid) == bvid else { return nil }
    let short = row["title"] as? String ?? ""
    let long = row["long_title"] as? String ?? ""
    let title = [short, long].filter { !$0.isEmpty }.joined(separator: " · ")
    return .init(id: id, video: Video(bvid: bvid, title: season + " · " + title,
      cover: row["cover"] as? String ?? cover, author: season,
      duration: (row["duration"] as? Int ?? 0) / 1000, views: 0, aid: row["aid"] as? Int,
      episodeID: id), cid: cid, title: title)
  }
}

struct CatalogSeason: Identifiable {
  let id: Int
  let title: String
  let cover: String
  let summary: String
  let episodes: [CatalogEpisode]
  let followed: Bool
  static func parse(_ row: [String: Any]) throws -> Self {
    guard let id = row["season_id"] as? Int, id > 0 else { throw BiliError(text: "剧集资料不可用") }
    let title = row["title"] as? String ?? "剧集"
    let cover = row["cover"] as? String ?? ""
    let sections = (row["section"] as? [[String: Any]] ?? []).flatMap { $0["episodes"] as? [[String: Any]] ?? [] }
    var seen = Set<Int>()
    let episodes = ((row["episodes"] as? [[String: Any]] ?? []) + sections)
      .compactMap { CatalogEpisode.parse($0, season: title, cover: cover) }
      .filter { seen.insert($0.id).inserted }
    return .init(id: id, title: title, cover: cover, summary: row["evaluate"] as? String ?? "",
      episodes: episodes, followed: (row["user_status"] as? [String: Any])?["follow"] as? Int == 1)
  }
}

extension API {
  func catalog(_ kind: CatalogKind, genre: Int, page: Int, followed: Bool, mid: Int?) async throws -> [CatalogItem] {
    let data: [String: Any]
    if kind == .live {
      if followed, mid != nil {
        data = try await request("/xlive/web-ucenter/v1/xfetter/GetWebList", ["page": String(page), "page_size": "24"])
      } else if genre == 0 {
        data = try await request("/xlive/web-interface/v1/webMain/getMoreRecList", ["platform": "web"])
      } else {
        data = try await request("/xlive/web-interface/v1/second/getList", [
          "platform": "web", "parent_area_id": String(genre), "area_id": "0", "sort_type": "online", "page": String(page)])
      }
    } else if followed, let mid {
      data = try await request("/x/space/bangumi/follow/list", [
        "vmid": String(mid), "type": kind == .bangumi ? "1" : "2", "pn": String(page), "ps": "24"])
    } else {
      data = try await request("/pgc/season/index/result", ["season_type": String(genre),
        "type": "1", "page": String(page), "pagesize": "24", "order": "3", "sort": "0"])
    }
    return (data["list"] as? [[String: Any]] ?? data["recommend_room_list"] as? [[String: Any]] ?? data["rooms"] as? [[String: Any]] ?? []).compactMap { CatalogItem.parse($0, live: kind == .live) }
  }

  func catalogSeason(_ id: Int, episode: Bool = false) async throws -> CatalogSeason {
    let data = try await request("/pgc/view/web/season", [episode ? "ep_id" : "season_id": String(id)])
    let season = try CatalogSeason.parse(data)
    var locations = catalogDefaults.dictionary(forKey: "catalogEpisodeIDs") as? [String: Int] ?? [:]
    let collection = VideoCollection(title: season.title,
      items: season.episodes.map { .init(bvid: $0.video.bvid, cid: $0.cid, title: $0.title) })
    for entry in season.episodes {
      catalogEpisodes[entry.video.bvid] = entry.id
      catalogDetails[entry.video.bvid] = Detail(video: entry.video, description: season.summary,
        pages: [Page(id: entry.cid, title: entry.title, number: 1, duration: entry.video.duration)],
        aid: entry.video.aid ?? 0, collection: collection)
      locations[entry.video.bvid] = entry.id
    }
    // Only public episode identifiers, never signed URLs or credentials.
    catalogDefaults.set(locations, forKey: "catalogEpisodeIDs")
    return season
  }

  func liveURL(room: Int) async throws -> URL {
    let data = try await request("/xlive/web-room/v2/index/getRoomPlayInfo", ["room_id": String(room),
      "protocol": "0,1", "format": "0,1,2", "codec": "0", "qn": "10000", "platform": "web", "ptype": "8"])
    guard data["live_status"] as? Int == 1 else { throw BiliError(text: "主播尚未开播") }
    let info = data["playurl_info"] as? [String: Any] ?? [:]
    let play = info["playurl"] as? [String: Any] ?? [:]
    return try Self.liveHLSURL(play)
  }

  nonisolated static func liveHLSURL(_ play: [String: Any]) throws -> URL { try liveHLSURLs(play)[0] }
  nonisolated static func liveHLSURLs(_ play: [String: Any]) throws -> [URL] {
    var urls: [URL] = []
    var seen = Set<URL>()
    for stream in play["stream"] as? [[String: Any]] ?? [] where stream["protocol_name"] as? String == "http_hls" {
      let formats = (stream["format"] as? [[String: Any]] ?? []).sorted {
        ($0["format_name"] as? String == "fmp4" ? 0 : 1) < ($1["format_name"] as? String == "fmp4" ? 0 : 1)
      }
      for format in formats {
        for codec in format["codec"] as? [[String: Any]] ?? [] where codec["codec_name"] as? String == "avc" {
          guard let path = codec["base_url"] as? String else { continue }
          for source in codec["url_info"] as? [[String: Any]] ?? [] {
            guard let host = source["host"] as? String,
              let url = BiliMediaCDNURLPolicy().normalizedURL(host + path + (source["extra"] as? String ?? "")) else { continue }
            if seen.insert(url).inserted { urls.append(url) }
          }
        }
      }
    }
    guard !urls.isEmpty else { throw BiliError(text: "没有可用的 HLS 直播线路，可重试或在官网观看") }
    return urls
  }
}

@MainActor @Observable final class CatalogModel {
  var items: [CatalogItem] = []
  var loading = false
  var hasMore = true
  var error: String?
  private var page = 0
  private var generation = UUID()
  func load(reset: Bool = false, loader: (Int) async throws -> [CatalogItem]) async {
    if reset { generation = UUID(); page = 0; loading = false; items = []; hasMore = true }
    guard !loading, hasMore else { return }
    let token = generation
    let next = page + 1
    loading = true; error = nil
    defer { if generation == token { loading = false } }
    do {
      let rows = try await loader(next)
      try Task.checkCancellation()
      guard token == generation else { return }
      let ids = Set(items.map(\.id))
      let fresh = rows.filter { !ids.contains($0.id) }
      var seen = Set<Int>()
      items += fresh.filter { seen.insert($0.id).inserted }
      hasMore = !fresh.isEmpty
      page = next
    } catch {
      guard token == generation, !(error is CancellationError) else { return }
      self.error = error.localizedDescription
    }
  }
}

struct CatalogPage: View {
  let store: Store
  let kind: CatalogKind
  var onPlay: ((String) -> Void)? = nil
  @State private var model = CatalogModel()
  @State private var genre: Int
  @State private var followed = false
  @State private var selected: CatalogItem?
  @State private var pendingEpisode: String?
  @State private var liveRoom: LiveRoomModel?
  @State private var roomNumber = ""
  @State private var submittedLiveQuery = ""
  init(store: Store, kind: CatalogKind, onPlay: ((String) -> Void)? = nil) {
    self.store = store; self.kind = kind; self.onPlay = onPlay
    _genre = State(initialValue: kind == .live ? 0 : kind == .bangumi ? 1 : 2)
  }
  private var categories: [(Int, String)] {
    kind == .live ? [(0, "全部"), (1, "娱乐"), (2, "网游"), (3, "手游"), (5, "电台"), (9, "虚拟主播")]
      : kind == .bangumi ? [(1, "番剧"), (4, "国创")]
      : [(2, "电影"), (5, "电视剧"), (3, "纪录片"), (7, "综艺")]
  }
  var body: some View {
    VStack(spacing: 14) {
      HStack {
        Label(kind.rawValue, systemImage: kind.symbol).font(AppMetrics.pageTitle)
        Spacer()
        Button { Task { await load(reset: true) } } label: { Image(systemName: "arrow.clockwise") }
          .disabled(model.loading).accessibilityLabel("刷新" + kind.rawValue)
        Button("官网") { store.webTarget = WebTarget(url: kind.website, title: kind.rawValue) }
      }
      HStack {
        Picker("分类", selection: $genre) { ForEach(categories, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.menu).frame(maxWidth: 240).moduleControl()
        Spacer()
        Toggle(kind == .live ? "关注的直播" : "我的追剧", isOn: $followed).toggleStyle(.switch).disabled(store.account == nil)
      }
      if kind == .live {
        HStack {
          TextField("搜索主播、标题或输入直播间号", text: $roomNumber).textFieldStyle(.roundedBorder).onSubmit(openRoom)
          Button("搜索", action: openRoom).disabled(roomNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          if !submittedLiveQuery.isEmpty { Button("清除搜索") { submittedLiveQuery = ""; roomNumber = "" } }
        }
      }
      ScrollView {
        LazyVStack(spacing: 20) {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: kind == .live ? 240 : 150, maximum: 320), alignment: .top)], spacing: 20) {
            ForEach(model.items) { item in
              Button {
                if kind == .live { openLive(item) }
                else { selected = item }
              } label: {
                VStack(alignment: .leading, spacing: 8) {
                  Thumbnail(url: item.cover, mode: .fill).aspectRatio(kind == .live ? 16 / 9 : 3 / 4, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: AppMetrics.mediaRadius))
                  Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                  Text([item.subtitle, item.badge].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(height: 18)
                }.contentShape(.rect)
              }.buttonStyle(.plain).accessibilityIdentifier("catalog-item-\(item.id)")
            }
          }
          if model.loading { ProgressView("正在加载") }
          if let error = model.error {
            Text(error).foregroundStyle(.secondary)
            Button("重试") { Task { await load() } }
          } else if !model.loading && model.items.isEmpty {
            ContentUnavailableView("暂无内容", systemImage: kind.symbol,
              description: Text(followed ? "关注剧集后会显示在这里" : "可刷新重试或在官网查看"))
          }
          if model.hasMore && !model.loading && !model.items.isEmpty {
            Button("加载更多") { Task { await load() } }.buttonStyle(.appGlassButton)
          }
        }
      }
    }.padding(AppMetrics.pageInset).controlSize(.regular).buttonStyle(.appGlassButton)
      .task(id: "\(genre):\(followed):\(store.account?.mid ?? 0):\(submittedLiveQuery)") { await load(reset: true) }
      .sheet(item: $selected, onDismiss: {
        if let bvid = pendingEpisode {
          pendingEpisode = nil
          if let onPlay { onPlay(bvid) } else { store.open(bvid) }
        }
      }) { item in
        CatalogSeasonView(store: store, seasonID: item.id) { episode in
          pendingEpisode = episode.video.bvid; selected = nil
        }
      }
      #if os(macOS)
      .sheet(item: $liveRoom) { model in CatalogLivePlayer(store: store, model: model) }
      .onChange(of: store.liveFullscreen.isPresented) { _, presented in
        guard !presented, let model = store.liveFullscreen.takeReturnedModel() else { return }
        let wasPlaying = model.player.timeControlStatus != .paused
        liveRoom = model
        // Remounting the inline AVKit view can pause the shared player.
        if wasPlaying { DispatchQueue.main.async { model.player.play() } }
      }
      #endif
      #if DEBUG && os(iOS)
      .task {
        if kind == .live, CatalogLivePlayer.fixture != nil, store.liveRoom == nil {
          openLive(CatalogItem(id: 1, title: "直播全屏回归测试", cover: "", subtitle: "本地测试", badge: ""))
        }
      }
      #endif
  }
  private func openRoom() {
    let text = roomNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    guard let id = Int(text), id > 0 else { submittedLiveQuery = text; return }
    openLive(CatalogItem(id: id, title: "直播间 \(id)", cover: "", subtitle: "", badge: ""))
  }
  private func openLive(_ item: CatalogItem) {
    store.playback.pausePlayback()
    #if os(iOS)
    store.liveRoom = LiveRoomModel(api: store.api, room: item)
    #else
    liveRoom = LiveRoomModel(api: store.api, room: item)
    #endif
  }
  private func load(reset: Bool = false) async {
    await model.load(reset: reset) { page in
      if kind == .live, !submittedLiveQuery.isEmpty { return try await store.api.searchLive(submittedLiveQuery, page: page) }
      return try await store.api.catalog(kind, genre: genre, page: page, followed: followed, mid: store.account?.mid)
    }
  }
}

struct CatalogSeasonView: View {
  let store: Store
  let seasonID: Int
  let play: (CatalogEpisode) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var season: CatalogSeason?
  @State private var followed = false
  @State private var busy = false
  @State private var error: String?
  @State private var retry = 0
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(season?.title ?? "剧集").font(.title2.bold())
        Spacer()
        Button("关闭") { dismiss() }
      }
      if let season {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text(season.summary).font(.callout).textSelection(.enabled)
            HStack {
              Button(followed ? "取消追剧" : "追剧") { Task { await follow() } }
                .disabled(busy || store.account == nil)
              Link("在官网观看", destination: URL(string: "https://www.bilibili.com/bangumi/play/ss\(seasonID)")!)
            }
            if store.account == nil { Text("登录后可同步追剧；播放权限以账号和地区为准。").font(.caption).foregroundStyle(.secondary) }
            ForEach(season.episodes) { episode in
              Button {
                play(episode)
              } label: {
                HStack { Image(systemName: "play.circle"); Text(episode.title); Spacer() }.padding(12)
              }.buttonStyle(.appGlassButton).accessibilityIdentifier("catalog-episode-\(episode.id)")
            }
            if season.episodes.isEmpty { Text("暂时没有可播放的分集，可在官网查看详情。") }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      } else if error == nil { ProgressView("正在加载剧集") }
      if let error { Text(error).foregroundStyle(.secondary); Button("重试") { retry += 1 } }
    }.padding(24).frame(minWidth: 300, idealWidth: 650, minHeight: 400, idealHeight: 650)
      .task(id: retry) {
        error = nil
        do {
          let loaded = try await store.api.catalogSeason(seasonID)
          try Task.checkCancellation()
          season = loaded; followed = loaded.followed
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
      }
  }
  private func follow() async {
    busy = true; error = nil
    defer { busy = false }
    do {
      _ = try await store.api.post(followed ? "/pgc/web/follow/del" : "/pgc/web/follow/add", ["season_id": String(seasonID)])
      followed.toggle()
    } catch { self.error = error.localizedDescription }
  }
}

#if os(iOS)
struct CatalogHub: View {
  let store: Store
  var onPlay: ((String) -> Void)? = nil
  @State private var kind: CatalogKind
  init(store: Store, initialKind: CatalogKind = .live, onPlay: ((String) -> Void)? = nil) {
    self.store = store; self.onPlay = onPlay
    _kind = State(initialValue: initialKind)
  }
  private var navigation = NavigationCustomization()
  var body: some View {
    VStack {
      Picker("内容", selection: $kind) {
        ForEach(CatalogKind.allCases.filter { navigation.preferences.allows($0.page) }) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).padding(.horizontal)
      CatalogPage(store: store, kind: kind, onPlay: onPlay).id(kind)
    }.navigationTitle("放映厅")
      .sheet(item: Binding(get: { store.webTarget }, set: { store.webTarget = $0 })) { MobileWebPage(store: store, target: $0) }
      .onAppear {
        if !navigation.preferences.allows(kind.page) {
          kind = CatalogKind.allCases.first { navigation.preferences.allows($0.page) } ?? .live
        }
      }
  }
}
#endif
