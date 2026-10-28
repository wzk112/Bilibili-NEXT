import AVKit
import ImageIO
import SwiftUI

struct PlaybackQueueItem: Identifiable, Equatable {
  var id: String { bvid + ":" + String(cid ?? 0) }
  let bvid: String
  var cid: Int? = nil
  let title: String
}
struct VideoCollection {
  let title: String
  let items: [PlaybackQueueItem]
  static func parse(_ raw: Any?) -> Self? {
    guard let raw = raw as? [String: Any] else { return nil }
    let episodes = (raw["sections"] as? [[String: Any]] ?? []).flatMap { $0["episodes"] as? [[String: Any]] ?? [] }
    var seen: Set<String> = []
    let items = episodes.compactMap { episode -> PlaybackQueueItem? in
      let arc = episode["arc"] as? [String: Any] ?? [:]
      guard let bvid = episode["bvid"] as? String ?? arc["bvid"] as? String, videoID(bvid) == bvid else { return nil }
      let cid = episode["cid"] as? Int ?? arc["cid"] as? Int
      let item = PlaybackQueueItem(bvid: bvid, cid: cid, title: episode["title"] as? String ?? arc["title"] as? String ?? bvid)
      return seen.insert(item.id).inserted ? item : nil
    }
    return items.isEmpty ? nil : Self(title: raw["title"] as? String ?? "合集", items: items)
  }
}
struct VideoSubtitle: Identifiable {
  let id: String
  let title: String
  let url: URL
}
struct SubtitleLine: Equatable {
  let start: Double
  let end: Double
  let text: String
  static func parse(_ raw: Any?) -> [Self] {
    (raw as? [[String: Any]] ?? []).compactMap { row in
      guard let start = row["from"] as? Double, let end = row["to"] as? Double,
        start.isFinite, end.isFinite, start >= 0, end > start, end <= 86400,
        let text = row["content"] as? String, !text.isEmpty else { return nil }
      return Self(start: start, end: end, text: text)
    }.sorted { $0.start < $1.start }
  }
}
struct VideoChapter: Identifiable {
  var id: Double { start }
  let start: Double
  let title: String
}
struct VideoTag: Identifiable {
  let id: Int
  let title: String
}
struct VideoShots {
  let times: [Double]
  let urls: [URL]
  let columns: Int
  let rows: Int
  var cellWidth = 0
  var cellHeight = 0
  static func binaryTimes(_ data: Data) throws -> [Double] {
    guard !data.isEmpty, data.count.isMultiple(of: 2), data.count <= 200_000 else { throw BiliError(text: "预览时间表无效") }
    let bytes = Array(data)
    let times = stride(from: 0, to: bytes.count, by: 2).map { Double(Int(bytes[$0]) << 8 | Int(bytes[$0 + 1])) }
    guard zip(times, times.dropFirst()).allSatisfy({ $0 <= $1 }) else { throw BiliError(text: "预览时间表无效") }
    return times
  }
  func frame(at time: Double) -> VideoPreviewFrame? {
    guard time.isFinite, (1...100).contains(columns), (1...100).contains(rows), !times.isEmpty else { return nil }
    let index = max(0, times.partitioningIndex { $0 > time } - 1)
    let sheet = index / (columns * rows)
    guard urls.indices.contains(sheet) else { return nil }
    return VideoPreviewFrame(url: urls[sheet], index: index % (columns * rows), columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
  }
}
extension Array where Element == Double {
  fileprivate func partitioningIndex(_ predicate: (Double) -> Bool) -> Int {
    var lower = 0, upper = count
    while lower < upper { let middle = (lower + upper) / 2; if predicate(self[middle]) { upper = middle } else { lower = middle + 1 } }
    return lower
  }
}

@MainActor @Observable final class VideoExtras {
  var related: [Video] = []
  var tags: [VideoTag] = []
  var subtitles: [VideoSubtitle] = []
  var chapters: [VideoChapter] = []
  var shots: VideoShots?
  var selectedSubtitle = ""
  var lines: [SubtitleLine] = []
  var error: String?
  var subtitleError: String?
  var loading = false
  private var key = ""
  private var generation = UUID()
  private var subtitleGeneration = UUID()
  func reset() {
    generation = UUID(); subtitleGeneration = UUID(); key = ""
    related = []; tags = []; subtitles = []; chapters = []; shots = nil; lines = []
    selectedSubtitle = ""; error = nil; subtitleError = nil; loading = false
  }
  func load(detail: Detail, cid: Int, api: API, refresh: Bool = false) async {
    let nextKey = detail.video.bvid + ":" + String(cid)
    guard refresh || key != nextKey else { return }
    reset(); key = nextKey; loading = true
    let token = generation
    async let recommendations = Result { try await api.request("/x/web-interface/archive/related", ["bvid": detail.video.bvid]) }
    async let metadata = Result { try await api.request("/x/player/wbi/v2", ["bvid": detail.video.bvid, "cid": String(cid)], signed: true) }
    async let tagResult = Result { try await api.request("/x/tag/archive/tags", ["bvid": detail.video.bvid]) }
    async let previews = Result { try await api.previewShots(aid: detail.aid, cid: cid) }
    let (r, m, t, p) = await (recommendations, metadata, tagResult, previews)
    guard token == generation else { return }
    guard !Task.isCancelled else { key = ""; loading = false; return }
    if case .success(let data) = r { related = Video.deduplicated((data["items"] as? [[String: Any]] ?? []).compactMap(Video.parse), excluding: [detail.video.bvid]) }
    else if case .failure(let failure) = r { error = failure.localizedDescription }
    if case .success(let data) = m {
      subtitles = ((data["subtitle"] as? [String: Any])?["subtitles"] as? [[String: Any]] ?? []).compactMap {
        guard let url = API.publicMediaURL($0["subtitle_url"] as? String ?? "") else { return nil }
        return VideoSubtitle(id: ($0["id_str"] as? String) ?? String(($0["id"] as? NSNumber)?.int64Value ?? 0), title: $0["lan_doc"] as? String ?? "字幕", url: url)
      }
      chapters = (data["view_points"] as? [[String: Any]] ?? []).compactMap {
        guard let start = ($0["from"] as? NSNumber)?.doubleValue, start.isFinite, start >= 0 else { return nil }
        return VideoChapter(start: start, title: $0["content"] as? String ?? "章节")
      }.sorted { $0.start < $1.start }
    } else if case .failure(let failure) = m { subtitleError = failure.localizedDescription }
    if case .success(let data) = t {
      tags = (data["items"] as? [[String: Any]] ?? []).compactMap {
        guard let id = $0["tag_id"] as? Int, let name = $0["tag_name"] as? String else { return nil }
        return VideoTag(id: id, title: name)
      }
    }
    if case .success(let previews) = p { shots = previews }
    loading = false
  }
  func selectSubtitle(_ id: String, api: API) async {
    subtitleGeneration = UUID(); let token = subtitleGeneration
    selectedSubtitle = id; lines = []; subtitleError = nil
    guard let track = subtitles.first(where: { $0.id == id }) else { return }
    do {
      let data = try await api.mediaJSON(track.url)
      guard token == subtitleGeneration, !Task.isCancelled else { return }
      lines = SubtitleLine.parse(data["body"])
    } catch { if token == subtitleGeneration { subtitleError = error.localizedDescription } }
  }
  func text(at time: Double) -> String {
    // Binary search the current cue; retain overlapping cues from the same track.
    var lower = 0, upper = lines.count
    while lower < upper { let middle = (lower + upper) / 2; if lines[middle].start <= time { lower = middle + 1 } else { upper = middle } }
    return lines[max(0, lower - 8)..<lower].filter { $0.start <= time && time < $0.end }.map(\.text).joined(separator: "\n")
  }
}
extension Result where Failure == Error {
  init(catching body: () async throws -> Success) async {
    do { self = .success(try await body()) } catch { self = .failure(error) }
  }
}
extension API {
  func previewShots(aid: Int, cid: Int) async throws -> VideoShots {
    let data = try await request("/x/player/videoshot", ["aid": String(aid), "cid": String(cid), "index": "1"])
    return try await previewShots(data: data, cid: cid)
  }
  func previewShots(data: [String: Any], cid: Int) async throws -> VideoShots {
    let row = (data["video_shots"] as? [String: [String: Any]])?[String(cid)] ?? data
    var times = ((row["index"] ?? (data["indexs"] as? [String: Any])?[String(cid)]) as? [NSNumber] ?? []).map(\.doubleValue)
    if times.isEmpty, let url = Self.publicMediaURL(row["pvdata"] as? String ?? "") {
      // Modern responses may omit JSON index entirely and advertise a public
      // timestamp file instead. Its entries are unsigned 16-bit big-endian seconds.
      var request = URLRequest(url: url); Self.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
      let (blob, response) = try await session.data(for: request)
      try Task.checkCancellation()
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BiliError(text: "预览时间表暂不可用") }
      times = try VideoShots.binaryTimes(blob)
    }
    let shots = VideoShots(times: times, urls: (row["image"] as? [String] ?? []).compactMap(Self.publicMediaURL),
      columns: row["img_x_len"] as? Int ?? 0, rows: row["img_y_len"] as? Int ?? 0,
      cellWidth: row["img_x_size"] as? Int ?? 0, cellHeight: row["img_y_size"] as? Int ?? 0)
    guard !times.isEmpty, times.allSatisfy({ $0.isFinite && $0 >= 0 }),
      zip(times, times.dropFirst()).allSatisfy({ $0 <= $1 }),
      shots.frame(at: 0) != nil else { throw BiliError(text: "预览时间表暂不可用") }
    return shots
  }
  nonisolated static func publicMediaURL(_ raw: String) -> URL? {
    guard var url = URLComponents(string: raw.hasPrefix("//") ? "https:" + raw : raw),
      ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil,
      let host = url.host?.lowercased(), ["hdslb.com", "biliimg.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
    url.scheme = "https"; return url.url
  }
  func mediaJSON(_ url: URL) async throws -> [String: Any] {
    guard Self.publicMediaURL(url.absoluteString) != nil else { throw BiliError(text: "资源地址无效") }
    var request = URLRequest(url: url); Self.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16 * 1024 * 1024,
      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BiliError(text: "资源暂时不可用") }
    return result
  }
}
#if os(macOS)
struct SubtitleOverlay: View {
  let extras: VideoExtras
  let playback: Playback
  var fullscreen = false
  var body: some View {
    let text = extras.text(at: playback.positionSeconds)
    VStack { Spacer(); if !text.isEmpty {
      Text(text).font(.system(size: fullscreen ? 25 : 20, weight: .medium)).multilineTextAlignment(.center)
        .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 5)
        .background(.black.opacity(0.65), in: .rect(cornerRadius: 6)).padding(.horizontal, 35)
        .padding(.bottom, fullscreen ? 100 : 18)
    } }.allowsHitTesting(false)
  }
}
struct PlaybackFeatureControls: View {
  @Bindable var store: Store
  @AppStorage("autoPlayNext") private var autoNext = false
  @AppStorage("autoPlayParts") private var autoParts = true
  @AppStorage("loopVideo") private var loop = false
  @State private var danmakuManager = false
  var body: some View {
    HStack(spacing: 12) {
      Menu {
        Button("关闭字幕") { Task { await store.extras.selectSubtitle("", api: store.api) } }
        ForEach(store.extras.subtitles) { track in
          Button { Task { await store.extras.selectSubtitle(track.id, api: store.api) } } label: {
            if store.extras.selectedSubtitle == track.id { Label(track.title, systemImage: "checkmark") } else { Text(track.title) }
          }
        }
        if store.extras.subtitles.isEmpty { Text(store.extras.loading ? "正在读取字幕" : "该视频暂无字幕") }
      } label: { Label("字幕", systemImage: "captions.bubble") }
      if !store.extras.chapters.isEmpty {
        Menu("章节") { ForEach(store.extras.chapters) { chapter in Button(chapter.title) { store.playback.seek(to: chapter.start) } } }
      }
      if store.hasNextVideo { Button { store.playNext() } label: { Label("下一集", systemImage: "forward.end") } }
      Menu {
        Toggle("分 P 自动连播", isOn: $autoParts)
        Toggle("合集与播放列表自动连播", isOn: $autoNext)
        Toggle("单集循环", isOn: $loop)
      } label: { Label("播放顺序", systemImage: "list.bullet") }
      Button { store.playback.showsSystemControls.toggle() } label: { Label(store.playback.showsSystemControls ? "关闭系统控件" : "画中画…", systemImage: "pip.enter") }
        .help("显示系统播放器控件，可从中进入画中画")
      Button("弹幕列表") { danmakuManager = true }
      Spacer()
      if let error = store.extras.subtitleError { Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
    }.buttonStyle(.glass).sheet(isPresented: $danmakuManager) { DanmakuManagement(store: store) }
  }
}
struct VideoDiscovery: View {
  @Bindable var store: Store
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if !store.extras.tags.isEmpty {
        ScrollView(.horizontal) { HStack { ForEach(store.extras.tags) { tag in Button(tag.title) { store.query = tag.title; store.search() }.buttonStyle(.glass) } } }
      }
      let parts = PlaybackSequence.parts(store.playback.detail)
      if !parts.isEmpty { sequence("分 P · \(parts.count) P", items: parts, parts: true) }
      if let collection = store.playback.detail?.collection, !collection.items.isEmpty {
        sequence("合集 · " + collection.title, items: collection.items, parts: false)
      }
      if !store.playQueue.isEmpty && store.playback.detail?.collection == nil {
        sequence("播放列表 · " + store.queueTitle, items: store.playQueue, parts: false)
      }
      HStack { Text("相关推荐").font(.title3.bold()); Spacer(); if store.extras.loading { ProgressView().controlSize(.small) } }
      if let error = store.extras.error {
        ErrorBanner(text: error) { Task { if let detail = store.playback.detail { await store.extras.load(detail: detail, cid: store.playback.selectedCID, api: store.api, refresh: true) } } }
      }
      ScrollView(.horizontal) {
        LazyHStack(alignment: .top, spacing: 12) { ForEach(store.extras.related) { video in
          Button { store.open(video.bvid) } label: { VideoCard(video: video).frame(width: 240) }.buttonStyle(.plain).contextMenu { VideoContextActions(store: store, video: video) }
        } }
      }.frame(height: store.extras.related.isEmpty ? 0 : 250)
    }
  }
  private func sequence(_ title: String, items: [PlaybackQueueItem], parts: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(title, systemImage: parts ? "rectangle.split.3x1" : "rectangle.stack").font(.headline)
      GlassEffectContainer(spacing: 10) {
        ScrollView(.horizontal) {
          LazyHStack(spacing: 10) {
            ForEach(items) { item in
              let current = item.bvid == store.playback.detail?.video.bvid
                && (!parts || item.cid == store.playback.selectedCID)
              Button {
                if !parts { store.playQueue = items; store.queueTitle = title }
                store.playQueueItem(item)
              } label: {
                Text(item.title).font(.callout.weight(current ? .semibold : .regular))
                  .lineLimit(2).frame(width: 180, height: 40, alignment: .leading)
                  .padding(.horizontal, 12).padding(.vertical, 8).foregroundStyle(.primary)
                  .contentShape(.rect(cornerRadius: 12))
              }.buttonStyle(InterfacePressStyle())
                .glassEffect(.regular.tint(current ? biliPink.opacity(0.22) : .clear).interactive(),
                  in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(current ? biliPink.opacity(0.7) : .clear, lineWidth: 1))
                .accessibilityAddTraits(current ? .isSelected : [])
            }
          }.padding(4)
        }.scrollIndicators(.hidden).frame(height: 66)
      }
    }.padding(14).floatingGlass(16)
  }

}

#endif
