import SwiftUI

struct MessageShare: Hashable {
  let title: String
  let author: String
  let cover: String
  let label: String
  let bvid: String?
  let aid: Int?
  let url: URL?
  var isVideo: Bool { label == "视频" }

  static func parse(_ object: [String: Any], type: Int) -> MessageShare? {
    guard [7, 11, 14].contains(type) else { return nil }
    func number(_ key: String) -> Int? {
      let value = (object[key] as? NSNumber)?.intValue ?? (object[key] as? String).flatMap(Int.init)
      return value.flatMap { $0 > 0 ? $0 : nil }
    }
    let source = number("source")
    let isVideo = type == 11 || (type == 7 && [5, 9].contains(source ?? 0))
    let link = safeURL(object["url"] as? String ?? object["jump_uri"] as? String ?? "")
    let bvid = isVideo ? videoID(object["bvid"] as? String ?? link?.absoluteString ?? "") : nil
    let aid = isVideo ? number(type == 11 ? "rid" : "id") : nil
    let labels = [2: "相簿", 3: "动态", 4: "直播", 6: "专栏", 7: "番剧", 8: "音乐", 10: "图片", 11: "动态", 16: "番剧", 17: "番剧"]
    let label = isVideo ? "视频" : labels[source ?? 0] ?? (type == 14 ? "直播" : "分享")
    let rawTitle = object["title"] as? String ?? object["headline"] as? String ?? ""
    let title = cleanTitle(rawTitle.trimmingCharacters(in: .whitespacesAndNewlines))
    let cover = safeURL(object["thumb"] as? String ?? object["cover"] as? String ?? "")?.absoluteString ?? ""
    return MessageShare(title: title.isEmpty ? "分享的\(label)" : title,
      author: object["author"] as? String ?? "", cover: cover, label: label,
      bvid: bvid, aid: aid, url: link)
  }
  private static func safeURL(_ string: String) -> URL? {
    let value = string.hasPrefix("//") ? "https:" + string : string
    guard var components = URLComponents(string: value),
      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
      let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return nil }
    components.scheme = "https"
    return components.url
  }
  @MainActor func resolveVideo(api: API) async throws -> String {
    if let bvid { return bvid }
    guard isVideo, let aid else { throw BiliError(text: "这条分享没有可用的视频地址") }
    let response = try await api.request("/x/web-interface/view", ["aid": String(aid)])
    guard let raw = response["bvid"] as? String, let bvid = videoID(raw) else {
      throw BiliError(text: "视频已失效或暂时不可用")
    }
    return bvid
  }
}

#if os(macOS)
struct MessageShareCard: View {
  let share: MessageShare
  @Bindable var store: Store
  @State private var opening = false
  @State private var error: String?
  @State private var task: Task<Void, Never>?
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(action: open) {
        VStack(alignment: .leading, spacing: 10) {
          Thumbnail(url: share.cover, mode: .fill, placeholder: "play.rectangle")
            .frame(height: 150).clipped().clipShape(.rect(cornerRadius: 12))
            .overlay {
              if opening { ProgressView().padding(12).appGlassEffect(.regular, in: .circle) }
              else if share.isVideo {
                Image(systemName: "play.fill").font(.title3).foregroundStyle(.white)
                  .padding(12).background(.black.opacity(0.5), in: .circle)
              }
            }
          Text(share.title).font(.headline).lineLimit(3).multilineTextAlignment(.leading)
          HStack {
            Text(share.author.isEmpty ? share.label : share.author).lineLimit(1)
            Spacer(minLength: 8)
            Label(share.label, systemImage: share.isVideo ? "play.rectangle" : "link")
          }.font(.caption).foregroundStyle(.secondary)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(opening).help(share.isVideo ? "在应用中播放" : "查看分享")
      if let error { Text(error).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }.frame(width: 268)
      .onDisappear { task?.cancel() }
  }
  private func open() {
    guard share.isVideo else {
      if let url = share.url { NSWorkspace.shared.open(url) }
      else { error = "这条分享没有可用的链接" }
      return
    }
    opening = true; error = nil
    let revision = store.navigationRevision
    task = Task {
      defer { opening = false }
      do {
        let bvid = try await share.resolveVideo(api: store.api)
        try Task.checkCancellation()
        guard revision == store.navigationRevision else { return }
        store.open(bvid)
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
  }
}

#endif
