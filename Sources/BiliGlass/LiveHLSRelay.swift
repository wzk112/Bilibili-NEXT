import BiliNetworking
import BiliPlayback
import Foundation

private final class LiveRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(request.url.map { $0.scheme == "https" && BiliMediaCDNURLPolicy().allows($0) } == true ? request : nil)
  }
}

/// AVPlayer reads a local HLS session; all upstream reads obey the app's proxy policy.
actor LiveHLSRelay {
  private let server = LoopbackPlaybackServer()
  private let network: BiliNetworkSession
  private var routes: [URL: (path: String, local: URL)] = [:]
  private var order: [URL] = []
  private var active = true
  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 20
    network = BiliNetworkSession(configuration: configuration, delegate: LiveRedirectPolicy())
  }
  func start(url: URL) async throws -> URL {
    guard BiliMediaCDNURLPolicy().allows(url) else { throw BiliError(text: "直播线路无效") }
    try await server.start()
    _ = try await fetch(url)
    return try register(url)
  }
  func stop() { active = false; server.stop(); routes = [:]; order = [] }
  private func register(_ remote: URL) throws -> URL {
    guard active, BiliMediaCDNURLPolicy().allows(remote) else { throw CancellationError() }
    if let existing = routes[remote] { return existing.local }
    let ext = remote.pathExtension.lowercased()
    let playlist = ext == "m3u8"
    let path = UUID().uuidString + "." + (playlist ? "m3u8" : ext == "ts" ? "ts" : ext == "key" ? "key" : "mp4")
    let mime = playlist ? "application/vnd.apple.mpegurl" : ext == "ts" ? "video/mp2t" : ext == "key" ? "application/octet-stream" : "video/mp4"
    let resource = try LoopbackGeneratedResource(contentType: mime, maximumContentLength: 16 * 1024 * 1024,
      maximumLoadAttempts: Int.max, cacheBody: false) { [weak self] in
        guard let self else { throw CancellationError() }
        return try await self.fetch(remote)
      }
    let local = try server.register(.generated(resource), at: path)
    routes[remote] = (path, local)
    if !playlist { order.append(remote) }
    // Keep live memory and route count bounded during long broadcasts.
    if order.count > 128 {
      let expired = order.removeFirst()
      if let old = routes.removeValue(forKey: expired) { try? server.unregister(at: old.path) }
    }
    return local
  }
  private func fetch(_ url: URL) async throws -> Data {
    guard active else { throw CancellationError() }
    var request = URLRequest(url: url)
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    request.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer")
    let (bytes, response) = try await network.session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
      response.url.map({ BiliMediaCDNURLPolicy().allows($0) }) == true else { throw BiliError(text: "直播线路暂不可用") }
    let maximum = url.pathExtension.lowercased() == "m3u8" ? 1024 * 1024 : 16 * 1024 * 1024
    if response.expectedContentLength > maximum { throw BiliError(text: "直播分段数据异常") }
    var data = Data()
    for try await byte in bytes {
      if data.count >= maximum { throw BiliError(text: "直播分段数据异常") }
      data.append(byte)
    }
    try Task.checkCancellation()
    guard active else { throw CancellationError() }
    if url.pathExtension.lowercased() != "m3u8" { return data }
    guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw BiliError(text: "直播播放列表无效") }
    let rewritten = try Self.rewrite(text, base: response.url ?? url) { try register($0).absoluteString }
    return Data(rewritten.utf8)
  }
  static func rewrite(_ text: String, base: URL, local: (URL) throws -> String) throws -> String {
    func resolve(_ raw: String) throws -> String {
      guard let absolute = URL(string: raw, relativeTo: base)?.absoluteURL,
        let url = BiliMediaCDNURLPolicy().normalizedURL(absolute.absoluteString) else {
        throw BiliError(text: "直播播放列表包含不可用线路")
      }
      return try local(url)
    }
    let regex = try NSRegularExpression(pattern: "URI=\"([^\"]+)\"")
    return try text.components(separatedBy: .newlines).map { line in
      if line.isEmpty { return line }
      if !line.hasPrefix("#") { return try resolve(line.trimmingCharacters(in: .whitespaces)) }
      var output = line
      for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
        guard let range = Range(match.range(at: 1), in: output) else { continue }
        output.replaceSubrange(range, with: try resolve(String(output[range])))
      }
      return output
    }.joined(separator: "\n")
  }
  deinit { server.stop() }
}
