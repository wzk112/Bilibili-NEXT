import BiliNetworking
import Foundation

enum LiveAvailability {
  // Keep the implementation dormant until the Mac live feature is ready.
  static let enabled = false
  static let message = "直播功能开发中"
}

struct SeasonSummary: Identifiable, Equatable {
  let id: Int
  let title: String
  let cover: String
  let subtitle: String
  let badge: String
  init?(_ json: [String: Any]) {
    guard let id = json["season_id"] as? Int, id > 0, let title = json["title"] as? String else { return nil }
    self.id = id
    self.title = cleanTitle(title)
    cover = json["cover"] as? String ?? ""
    subtitle = json["index_show"] as? String ?? (json["new_ep"] as? [String: Any])?["index_show"] as? String ?? json["subTitle"] as? String ?? ""
    badge = json["badge"] as? String ?? ""
  }
}

struct SeasonEpisode: Identifiable, Equatable {
  let id: Int
  let bvid: String
  let aid: Int
  let cid: Int
  let title: String
  let cover: String
  let duration: Int
  let badge: String
  let areaLimited: Bool
  init?(_ json: [String: Any]) {
    guard let id = json["id"] as? Int ?? json["ep_id"] as? Int, id > 0 else { return nil }
    self.id = id; bvid = json["bvid"] as? String ?? ""
    aid = json["aid"] as? Int ?? 0; cid = json["cid"] as? Int ?? 0
    let short = json["title"] as? String ?? ""
    let long = json["long_title"] as? String ?? ""
    title = json["show_title"] as? String ?? [short, long].filter { !$0.isEmpty }.joined(separator: " · ")
    cover = json["cover"] as? String ?? ""
    duration = max(0, (json["duration"] as? Int ?? 0) / 1000)
    badge = json["badge"] as? String ?? ""
    areaLimited = (json["rights"] as? [String: Any])?["area_limit"] as? Int == 1
  }
}

struct SeasonEpisodeGroup: Identifiable, Equatable {
  let id: Int
  let title: String
  let episodes: [SeasonEpisode]
}

struct SeasonDetail: Identifiable, Equatable {
  let id: Int
  let title: String
  let cover: String
  let description: String
  let episodes: [SeasonEpisode]
  let episodeGroups: [SeasonEpisodeGroup]
  let mainEpisodeIDs: Set<Int>
  var following: Bool
  init(_ json: [String: Any]) throws {
    guard let id = json["season_id"] as? Int, id > 0 else { throw BiliError(text: "节目详情无效") }
    self.id = id; title = json["title"] as? String ?? "节目"
    cover = json["cover"] as? String ?? ""; description = json["evaluate"] as? String ?? ""
    let main = json["episodes"] as? [[String: Any]] ?? []
    let sections = json["section"] as? [[String: Any]] ?? []
    var seen = Set<Int>()
    let primary = main.compactMap(SeasonEpisode.init).filter { seen.insert($0.id).inserted }
    mainEpisodeIDs = Set(primary.map(\.id))
    var groups: [SeasonEpisodeGroup] = primary.isEmpty ? [] : [.init(id: 0, title: "正片", episodes: primary)]
    for (index, section) in sections.enumerated() {
      let rows = (section["episodes"] as? [[String: Any]] ?? []).compactMap(SeasonEpisode.init).filter { seen.insert($0.id).inserted }
      if !rows.isEmpty { groups.append(.init(id: index + 1, title: section["title"] as? String ?? "特别内容", episodes: rows)) }
    }
    episodeGroups = groups; episodes = groups.flatMap(\.episodes)
    following = (json["user_status"] as? [String: Any])?["follow"] as? Int == 1
  }
  func queue(for episode: SeasonEpisode) -> [SeasonEpisode] {
    mainEpisodeIDs.contains(episode.id) ? episodes.filter { mainEpisodeIDs.contains($0.id) } : [episode]
  }
}

struct LiveRoom: Identifiable, Equatable {
  let id: Int
  let title: String
  let author: String
  let cover: String
  let area: String
  let online: Int
  let isLive: Bool
  init?(_ json: [String: Any]) {
    guard let id = json["roomid"] as? Int ?? json["room_id"] as? Int, id > 0 else { return nil }
    self.id = id
    title = cleanTitle(json["title"] as? String ?? "直播间")
    author = json["uname"] as? String ?? ""
    cover = json["cover"] as? String ?? json["user_cover"] as? String ?? json["keyframe"] as? String ?? ""
    area = json["area_v2_name"] as? String ?? json["area_name"] as? String ?? ""
    online = json["online"] as? Int ?? 0
    isLive = json["live_status"] as? Int != 0
  }
  static func roomID(_ raw: String) -> Int? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = Int(text), id > 0 { return id }
    guard let url = URL(string: text), ["live.bilibili.com", "m.live.bilibili.com"].contains(url.host ?? "") else { return nil }
    var parts = Array(url.pathComponents.dropFirst())
    if parts.first == "blanc" { parts.removeFirst() }
    guard let first = parts.first, let id = Int(first), id > 0 else { return nil }
    return id
  }
}

struct LiveStream {
  let urls: [URL]
  let quality: Int
  let qualities: [Int: String]
  static func parse(_ json: [String: Any]) throws -> Self {
    let playurl = ((json["playurl_info"] as? [String: Any])?["playurl"] as? [String: Any]) ?? [:]
    var qualities: [Int: String] = [:]
    for entry in playurl["g_qn_desc"] as? [[String: Any]] ?? [] {
      if let qn = entry["qn"] as? Int { qualities[qn] = entry["desc"] as? String ?? "\(qn)" }
    }
    let streams = playurl["stream"] as? [[String: Any]] ?? []
    var candidates: [(Int, Int, [URL])] = []
    for stream in streams where stream["protocol_name"] as? String == "http_hls" {
      for format in stream["format"] as? [[String: Any]] ?? [] {
        for codec in format["codec"] as? [[String: Any]] ?? [] where ["avc", "hevc"].contains(codec["codec_name"] as? String ?? "") {
          let base = codec["base_url"] as? String ?? ""
          let urls = (codec["url_info"] as? [[String: Any]] ?? []).compactMap { row -> URL? in
            guard let host = row["host"] as? String else { return nil }
            return BiliMediaCDNURLPolicy().normalizedURL(host + base + (row["extra"] as? String ?? ""))
          }
          if !urls.isEmpty { candidates.append((codec["codec_name"] as? String == "avc" ? 0 : 1, codec["current_qn"] as? Int ?? 0, urls)) }
        }
      }
    }
    guard let best = candidates.sorted(by: { $0.0 < $1.0 }).first else { throw BiliError(text: "直播暂未提供可播放的 HLS 线路，请稍后重试") }
    return Self(urls: best.2, quality: best.1, qualities: qualities)
  }
}

extension API {
  func catalog(type: Int, page: Int, keyword: String = "") async throws -> ([SeasonSummary], Bool) {
    let data: [String: Any]
    let rows: [[String: Any]]
    if keyword.isEmpty {
      data = try await request("/pgc/season/index/result", ["season_type": "\(type)", "type": "1", "st": "\(type)", "order": "3", "sort": "0", "page": "\(page)", "pagesize": "20"])
      rows = data["list"] as? [[String: Any]] ?? []
    } else {
      data = try await request("/x/web-interface/search/type", ["search_type": [1,4].contains(type) ? "media_bangumi" : "media_ft", "keyword": keyword, "page": "\(page)", "page_size": "20"])
      rows = data["result"] as? [[String: Any]] ?? []
    }
    return (rows.compactMap(SeasonSummary.init), (data["has_next"] as? Int == 1 || data["has_next"] as? Bool == true) || (!keyword.isEmpty && page < (data["numPages"] as? Int ?? 1)))
  }
  func followedSeasons(type: Int, page: Int) async throws -> ([SeasonSummary], Bool) {
    guard signedIn, let mid = cookies["DedeUserID"] else { throw BiliError(text: "登录后查看我的追番和追剧") }
    let data = try await request("/x/space/bangumi/follow/list", ["vmid": mid, "type": [1,4].contains(type) ? "1" : "2", "pn": "\(page)", "ps": "20"])
    let rows = data["list"] as? [[String: Any]] ?? []
    return (rows.compactMap(SeasonSummary.init), page * 20 < (data["total"] as? Int ?? 0))
  }
  func season(id: Int) async throws -> SeasonDetail { try SeasonDetail(await request("/pgc/view/web/season", ["season_id": "\(id)"])) }
  func seasonStreams(episodeID: Int, cid: Int, quality: Int = 127) async throws -> Streams {
    let data = try await request("/pgc/player/web/playurl", ["ep_id": "\(episodeID)", "cid": "\(cid)", "qn": "\(quality)", "fnver": "0", "fnval": "4048", "fourk": "1"])
    if let code = data["code"] as? Int, code != 0 { throw BiliError(text: data["message"] as? String ?? "这一集暂不可播放", code: code) }
    return try Self.parseStreams(data)
  }
  func followSeason(_ id: Int, following: Bool) async throws {
    _ = try await post(following ? "/pgc/web/follow/add" : "/pgc/web/follow/del", ["season_id": "\(id)"])
  }
  func liveRooms(keyword: String = "") async throws -> [LiveRoom] {
    guard LiveAvailability.enabled else { throw BiliError(text: LiveAvailability.message) }
    if let id = LiveRoom.roomID(keyword) { return [try await liveRoom(id)] }
    let data = try await request(keyword.isEmpty ? "/xlive/web-interface/v1/webMain/getList" : "/x/web-interface/search/type",
      keyword.isEmpty ? ["platform": "web"] : ["search_type": "live_room", "keyword": keyword], live: keyword.isEmpty)
    let rows = data["recommend_room_list"] as? [[String: Any]] ?? data["result"] as? [[String: Any]] ?? []
    return rows.compactMap(LiveRoom.init)
  }
  func liveRoom(_ id: Int) async throws -> LiveRoom {
    guard LiveAvailability.enabled else { throw BiliError(text: LiveAvailability.message) }
    let data = try await request("/room/v1/Room/get_info", ["room_id": "\(id)"], live: true)
    guard let room = LiveRoom(data) else { throw BiliError(text: "未找到这个直播间") }
    return room
  }
  func liveStream(roomID: Int, quality: Int = 10000) async throws -> LiveStream {
    guard LiveAvailability.enabled else { throw BiliError(text: LiveAvailability.message) }
    return try LiveStream.parse(await request("/xlive/web-room/v2/index/getRoomPlayInfo",
      ["room_id": "\(roomID)", "protocol": "0,1", "format": "0,1,2", "codec": "0,1", "qn": "\(quality)", "platform": "web", "ptype": "8"], live: true))
  }
}
