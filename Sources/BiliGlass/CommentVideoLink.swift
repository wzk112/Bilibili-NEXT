import SwiftUI

struct CommentVideoLink: Hashable, Sendable {
  let url: URL
  let title: String
  static func allowedURL(_ raw: String) -> URL? {
    let raw = raw.hasPrefix("//") ? "https:" + raw : raw
    guard var parts = URLComponents(string: raw),
      ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
      parts.user == nil, parts.password == nil, parts.port == nil,
      let host = parts.host?.lowercased(),
      host == "b23.tv" || ((host == "bilibili.com" || host.hasSuffix(".bilibili.com"))
        && parts.path.hasPrefix("/video/")) else { return nil }
    parts.scheme = "https"; parts.query = nil; parts.fragment = nil
    return parts.url
  }
  static func parse(message: String, jumps: Any?) -> [CommentVideoLink] {
    let metadata = jumps as? [String: [String: Any]] ?? [:]
    guard message.utf16.count <= 64_000,
      let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>]+"#) else { return [] }
    var seen: Set<URL> = []
    var result: [CommentVideoLink] = []
    for match in regex.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
      guard let range = Range(match.range, in: message) else { continue }
      let raw = String(message[range]).trimmingCharacters(in: CharacterSet(charactersIn: "。，、；;！!？?）)]】>"))
      guard let url = allowedURL(raw), seen.insert(url).inserted else { continue }
      let title = metadata[raw]?["title"] as? String ?? "视频链接"
      result.append(CommentVideoLink(url: url, title: cleanTitle(title)))
      if result.count == 2 { break }
    }
    return result
  }
}

/// Inspect redirects without loading an HTML page or forwarding account cookies.
private final class VideoLinkRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class CommentVideoLinks {
  static let shared = CommentVideoLinks()
  private var cache: [URL: Video] = [:]
  private var order: [URL] = []
  private var failures: [URL: Date] = [:]
  private var inFlight: [URL: Task<Video?, Never>] = [:]
  private var active = 0
  private let networkSession: BiliNetworkSession
  init() {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 12
    config.httpMaximumConnectionsPerHost = 2
    networkSession = BiliNetworkSession(configuration: config, delegate: VideoLinkRedirects())
  }
  func resolve(_ link: CommentVideoLink, api: API) async -> Video? {
    if let cached = cache[link.url] { return cached }
    if let last = failures[link.url], Date().timeIntervalSince(last) < 60 { return nil }
    if let task = inFlight[link.url] { return await task.value }
    let task = Task { () -> Video? in
      while active >= 3 {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
      }
      active += 1
      defer { active -= 1 }
      do {
        var url = link.url
        for _ in 0..<5 where url.host?.lowercased() == "b23.tv" {
          var request = URLRequest(url: url)
          request.httpMethod = "HEAD"
          request.setValue(API.mediaHeaders["User-Agent"], forHTTPHeaderField: "User-Agent")
          let (_, response) = try await networkSession.session.data(for: request)
          guard let http = response as? HTTPURLResponse,
            (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
            let next = URL(string: location, relativeTo: url)?.absoluteURL,
            let allowed = CommentVideoLink.allowedURL(next.absoluteString) else { return nil }
          url = allowed
        }
        var query: [String: String] = [:]
        if let bvid = videoID(url.absoluteString) { query["bvid"] = bvid }
        else if url.lastPathComponent.hasPrefix("av"),
          let aid = Int(url.lastPathComponent.dropFirst(2)), aid > 0 { query["aid"] = String(aid) }
        guard !query.isEmpty else { return nil }
        return Video.parse(try await api.request("/x/web-interface/view", query))
      } catch { return nil }
    }
    inFlight[link.url] = task
    let video = await task.value
    inFlight[link.url] = nil
    if let video {
      while order.count >= 128 { cache[order.removeFirst()] = nil }
      cache[link.url] = video; order.append(link.url)
      failures[link.url] = nil
    } else {
      if failures.count >= 128 { failures = [:] }
      failures[link.url] = Date()
    }
    return video
  }
}

struct CommentVideoCard: View {
  let link: CommentVideoLink
  @Bindable var store: Store
  @State private var video: Video?
  @State private var loading = true
  var body: some View {
    Button {
      if let video { store.open(video.bvid) }
    } label: {
      HStack(spacing: 12) {
        Thumbnail(url: video?.cover ?? "", mode: .fill)
          .frame(width: 132, height: 74).clipShape(.rect(cornerRadius: 10))
          .overlay { if loading { ProgressView().controlSize(.small) } }
        VStack(alignment: .leading, spacing: 8) {
          Text(video?.title ?? link.title).font(.callout.weight(.medium))
            .lineLimit(2).multilineTextAlignment(.leading)
          Text(video?.author ?? (loading ? "正在读取视频" : "视频暂时不可用"))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        Image(systemName: "play.circle").font(.title2).foregroundStyle(.secondary)
      }.padding(10).frame(maxWidth: 520, alignment: .leading).appGlass(16)
        .contentShape(.rect(cornerRadius: 16))
    }.buttonStyle(.plain).disabled(video == nil).help("在应用中播放")
      .task(id: link) {
        loading = true
        let loaded = await CommentVideoLinks.shared.resolve(link, api: store.api)
        guard !Task.isCancelled else { return }
        video = loaded; loading = false
      }
  }
}
