import BiliModels
import BiliNetworking
import CryptoKit
import Foundation
import Security
import VideoToolbox

struct BiliError: LocalizedError {
  let text: String
  var code: Int? = nil
  var challenge: InteractionChallenge? = nil
  var requiresVerification: Bool { [-351, -352, -401, -403, -412].contains(code ?? 0) || text.contains("验证") }
  var errorDescription: String? { text }
}
struct Video: Identifiable, Codable, Hashable {
  var id: String { bvid }
  let bvid: String
  let title: String
  let cover: String
  let author: String
  let duration: Int
  let views: Int
  var publishedAt: Date? = nil
  var aid: Int? = nil
  var ownerID: Int? = nil
  var progress: Int? = nil
  var recommendationTrackID: String? = nil
  static func deduplicated(_ videos: [Video], excluding: Set<String> = []) -> [Video] {
    var seen = excluding
    return videos.filter { seen.insert($0.id).inserted }
  }
  static func parse(_ j: [String: Any]) -> Video? {
    guard let bvid = j["bvid"] as? String, bvid.hasPrefix("BV") else { return nil }
    let owner = j["owner"] as? [String: Any] ?? j["author"] as? [String: Any] ?? [:]
    let stat = j["stat"] as? [String: Any] ?? [:]
    let raw = j["duration"] as? String ?? j["length"] as? String ?? "0"
    let seconds = raw.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    return Video(
      bvid: bvid, title: cleanTitle(j["title"] as? String ?? "视频"),
      cover: j["pic"] as? String ?? j["cover"] as? String ?? "",
      author: owner["name"] as? String ?? j["author"] as? String ?? "",
      duration: j["duration"] as? Int ?? seconds,
      views: stat["view"] as? Int ?? j["play"] as? Int ?? 0,
      publishedAt: ((j["pubdate"] as? NSNumber)?.doubleValue ?? (j["created"] as? NSNumber)?.doubleValue).flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil },
      aid: j["aid"] as? Int ?? j["id"] as? Int, ownerID: owner["mid"] as? Int, progress: j["progress"] as? Int,
      recommendationTrackID: j["track_id"] as? String ?? j["trackid"] as? String)
  }
}
struct Page: Identifiable {
  let id: Int
  let title: String
  let number: Int
  var duration: Int = 0
}
struct Detail {
  let video: Video
  let description: String
  let pages: [Page]
  var aid: Int = 0
  var ownerID: Int = 0
  var ownerFace: String = ""
  var copyright: Int = 1
  var counts = VideoCounts()
  var collection: VideoCollection? = nil
}
struct Streams {
  let videos: [MediaRepresentation]
  let audio: MediaRepresentation
  let names: [Int: String]
  var diagnostics: [String: String] = [:]
}
struct StreamManifestError: LocalizedError {
  let kind: String
  let diagnostics: [String: String]
  var errorDescription: String? {
    "没有可用的\(kind == "audio" ? "音频" : "视频")播放源，请重试或在播放详情查看诊断信息。"
  }
}
private enum MediaRepresentationFailure: String, Error {
  case address, segmentBase, byteRange, attributes
}
enum VideoCodecPreference: String, CaseIterable, Identifiable, Sendable {
  case automatic = "auto", av1, hevc
  var id: String { rawValue }
  static var hardwareDecodeSummary: String {
    let formats: [(String, CMVideoCodecType)] = [
      ("H.264", kCMVideoCodecType_H264), ("HEVC", kCMVideoCodecType_HEVC), ("AV1", kCMVideoCodecType_AV1)
    ]
    let supported = formats.filter { VTIsHardwareDecodeSupported($0.1) }.map(\.0)
    return supported.isEmpty ? "系统未报告可用的硬件解码格式。" : "本机支持硬件解码：" + supported.joined(separator: "、") + "。"
  }
  var title: String {
    switch self { case .automatic: return "自动"; case .av1: return "优先 AV1"; case .hevc: return "优先 HEVC（H.265）" }
  }
}
struct Account {
  let name: String
  let mid: Int
  let face: String
}
func cleanTitle(_ s: String) -> String {
  s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).replacingOccurrences(
    of: "&amp;", with: "&"
  ).replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
}
func videoID(_ s: String) -> String? {
  s.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression).map { String(s[$0]) }
}
func safeFilename(_ s: String) -> String {
  let result = s.components(
    separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n\r").union(.controlCharacters)
  ).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
  return String((result.isEmpty ? "视频" : result).prefix(100))
}

final class Vault {
  static let service = sessionService(bundleIdentifier: Bundle.main.bundleIdentifier)
  static func sessionService(bundleIdentifier: String?) -> String {
    // Independently signed local QA apps must never request or overwrite the
    // installed release's credentials. Keep the release service for upgrades.
    guard let bundleIdentifier, bundleIdentifier.hasSuffix(".FeedbackQA") else {
      return "local.BiliGlass.session"
    }
    return bundleIdentifier + ".session"
  }
  static func save(_ data: Data, account: String = "cookies") throws {
    let q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var insert = q
      insert[kSecValueData as String] = data
      insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let added = SecItemAdd(insert as CFDictionary, nil)
      guard added == errSecSuccess else { throw BiliError(text: "无法保存登录：\(added)") }
    } else if status != errSecSuccess {
      throw BiliError(text: "无法保存登录：\(status)")
    }
  }
  static func load(account: String = "cookies") -> Data? {
    var value: CFTypeRef?
    let status = SecItemCopyMatching(
      [
        kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
        kSecAttrAccount as String: account, kSecReturnData as String: true,
      ] as CFDictionary, &value)
    return status == errSecSuccess ? value as? Data : nil
  }
  static func clear(account: String = "cookies") {
    SecItemDelete(
      [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
       kSecAttrAccount as String: account] as CFDictionary)
  }
}

@MainActor final class API {
  nonisolated static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  nonisolated static let mediaHeaders = [
    "User-Agent": userAgent, "Referer": "https://www.bilibili.com/",
  ]
  let session: URLSession
  var cookies: [String: String] = [:]
  var appCoinAuthorization: AppCoinAuthorization?
  private var wbiKey: String?
  private var navigationTask: (id: UUID, task: Task<[String: Any], Error>)?
  var authenticationGeneration = UUID()
  var interactionVerification: InteractionVerificationGrant?
  var dynamicCursor = ""
  var dynamicHasMore = true
  private let searchID = UUID().uuidString.lowercased() + "infoc"
  private let credentialAccount: String
  private var legacyAuthorizationAccount: String {
    credentialAccount == "cookies" ? AppCoinAuthorization.vaultAccount : credentialAccount + ".legacy-authorization"
  }
  init(loadCredentials: Bool = true, transport: URLSession? = nil, credentialAccount: String = "cookies") {
    self.credentialAccount = credentialAccount
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.timeoutIntervalForRequest = 25
    c.urlCache = nil
    session = transport ?? URLSession(configuration: c)
    if loadCredentials, let data = Vault.load(account: credentialAccount), let saved = StoredLogin.decode(data)
    {
      cookies = saved.cookies
      appCoinAuthorization = saved.appCoinAuthorization
      if appCoinAuthorization == nil, let data = Vault.load(account: legacyAuthorizationAccount) {
        appCoinAuthorization = try? JSONDecoder().decode(AppCoinAuthorization.self, from: data)
      }
    }
  }
  func restoreCredentials(read: @escaping @Sendable (String) -> Data? = { Vault.load(account: $0) }) async {
    let generation = authenticationGeneration
    let account = credentialAccount
    let legacy = legacyAuthorizationAccount
    let (data, appData) = await Task.detached(priority: .userInitiated) {
      (read(account), read(legacy))
    }.value
    guard !Task.isCancelled, generation == authenticationGeneration, let data,
      let saved = StoredLogin.decode(data)
    else { return }
    // Home feeds can ask for WBI before the Keychain read finishes. Their guest
    // navigation response belongs to the old session, even if it arrives later.
    navigationTask?.task.cancel()
    navigationTask = nil
    authenticationGeneration = UUID()
    interactionVerification = nil
    wbiKey = nil
    cookies = saved.cookies
    appCoinAuthorization = saved.appCoinAuthorization
      ?? appData.flatMap { try? JSONDecoder().decode(AppCoinAuthorization.self, from: $0) }
  }
  func saveClientLogin(_ login: StoredLogin) throws {
    guard let token = login.appCoinAuthorization, token.isValid(for: login.cookies["DedeUserID"]),
      login.cookies["SESSDATA"] != nil, login.cookies["bili_jct"] != nil else {
      throw BiliError(text: "登录信息不完整，保留原登录")
    }
    try Vault.save(JSONEncoder().encode(login), account: credentialAccount)
    navigationTask?.task.cancel(); navigationTask = nil
    cookies = login.cookies
    appCoinAuthorization = token
    authenticationGeneration = UUID()
    interactionVerification = nil
    wbiKey = nil
    Vault.clear(account: legacyAuthorizationAccount)
    WebSession.shared.reset()
  }
  func saveWebLogin(_ webCookies: [String: String]) throws {
    let login = try StoredLogin.webLogin(cookies: webCookies, previous: appCoinAuthorization)
    try Vault.save(JSONEncoder().encode(login), account: credentialAccount)
    navigationTask?.task.cancel(); navigationTask = nil
    cookies = login.cookies
    appCoinAuthorization = login.appCoinAuthorization
    authenticationGeneration = UUID()
    interactionVerification = nil
    wbiKey = nil
    Vault.clear(account: legacyAuthorizationAccount)
  }
  var signedIn: Bool { cookies["SESSDATA"] != nil }
  func logout() {
    navigationTask?.task.cancel()
    navigationTask = nil
    authenticationGeneration = UUID()
    interactionVerification = nil
    cookies = [:]
    appCoinAuthorization = nil
    Vault.clear(account: credentialAccount)
    Vault.clear(account: legacyAuthorizationAccount)
    WebSession.shared.reset()
    wbiKey = nil
  }
  func request(_ path: String, _ query: [String: String] = [:], signed: Bool = false) async throws
    -> [String: Any]
  {
    try Task.checkCancellation()
    let authentication = authenticationGeneration
    var params = query
    if signed {
      if wbiKey == nil { _ = try await nav() }
      if let key = wbiKey { params = Self.sign(params, key: key) }
    }
    let host =
      path.hasPrefix("/x/passport") ? "https://passport.bilibili.com" : "https://api.bilibili.com"
    var u = URLComponents(string: host + path)!
    u.queryItems = params.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    var req = URLRequest(url: u.url!)
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    API.mediaHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    if let bvid = params["bvid"] {
      req.setValue("https://www.bilibili.com/video/" + bvid + "/", forHTTPHeaderField: "Referer")
    }
    if path == "/x/space/wbi/arc/search" || path.contains("/web-space/"), let mid = params["mid"] {
      req.setValue(
        "https://space.bilibili.com/" + mid + "/upload/video", forHTTPHeaderField: "Referer")
    }
    req.setValue(
      (cookies.merging(
        (path.contains("search/") || path == "/x/space/wbi/arc/search") ? ["buvid3": searchID] : [:]
      ) { a, _ in a }).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(
        separator: "; "),
      forHTTPHeaderField: "Cookie")
    let (data, response) = try await session.data(for: req)
    try Task.checkCancellation()
    guard authentication == authenticationGeneration else { throw CancellationError() }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      #if DEBUG
        print("API HTTP", code, path)
      #endif
      throw BiliError(text: code == 412 ? "请求受限（412），请稍后重试或登录" : "连接失败（\(code)），请稍后重试", code: code)
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw BiliError(text: "返回数据无效")
    }
    let code = root["code"] as? Int ?? -1
    guard code == 0 || (path == "/x/web-interface/nav" && code == -101) else {
      throw BiliError(
        text: code == -101 ? "请重新登录" : "\(root["message"] as? String ?? "请求失败")（\(code)）", code: code)
    }
    if path == "/x/web-interface/nav", code == -101 {
      var result = root["data"] as? [String: Any] ?? [:]
      result["isLogin"] = false
      return result
    }
    if path.hasSuffix("qrcode/poll"), let result = root["data"] as? [String: Any],
      result["code"] as? Int == 0
    {
      // Only accept cookies from the exact passport host on successful QR confirmation.
      let fields = http.allHeaderFields.reduce(into: [String: String]()) {
        if let k = $1.key as? String, let v = $1.value as? String { $0[k] = v }
      }
      for c in HTTPCookie.cookies(withResponseHeaderFields: fields, for: req.url!)
      where ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"].contains(c.name) {
        cookies[c.name] = c.value
      }
      if !signedIn, let s = result["url"] as? String, let url = URLComponents(string: s) {
        for pair in url.queryItems ?? []
        where ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5"].contains(pair.name) {
          cookies[pair.name] = pair.value
        }
      }
      guard signedIn else { throw BiliError(text: "登录凭据缺失，请重新扫码") }
      authenticationGeneration = UUID()
      try Vault.save(JSONEncoder().encode(cookies), account: credentialAccount)
      appCoinAuthorization = nil
      Vault.clear(account: legacyAuthorizationAccount)
    }
    if let object = root["data"] as? [String: Any] { return object }
    if let array = root["data"] as? [Any] { return ["items": array] }
    if let result = root["result"] as? [String: Any] { return result }
    return ["value": root["data"] ?? NSNull()]
  }
  func messageRequest(_ path: String, _ values: [String: String] = [:], write: Bool = false)
    async throws -> [String: Any]
  {
    try Task.checkCancellation()
    let reads: Set<String> = [
      "/session_svr/v1/session_svr/get_sessions", "/svr_sync/v1/svr_sync/fetch_session_msgs",
      "/account/v1/user/cards", "/session_svr/v1/session_svr/single_unread",
    ]
    let writes: Set<String> = [
      "/web_im/v1/web_im/send_msg", "/session_svr/v1/session_svr/update_ack",
    ]
    guard (write ? writes : reads).contains(path), signedIn else { throw BiliError(text: "请先登录") }
    var params = values
    var components = URLComponents(string: "https://api.vc.bilibili.com" + path)!
    if write {
      guard let csrf = cookies["bili_jct"] else { throw BiliError(text: "登录信息已失效") }
      params["csrf"] = csrf
      params["csrf_token"] = csrf
      if path.hasSuffix("send_msg") {
        if wbiKey == nil { _ = try await nav() }
        let query = [
          "w_sender_uid": params["msg[sender_uid]"] ?? "",
          "w_receiver_id": params["msg[receiver_id]"] ?? "",
          "w_dev_id": params["msg[dev_id]"] ?? "",
        ]
        components.queryItems = (wbiKey.map { Self.sign(query, key: $0) } ?? query).map {
          URLQueryItem(name: $0.key, value: $0.value)
        }
      }
    } else {
      components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    var request = URLRequest(url: components.url!)
    request.httpMethod = write ? "POST" : "GET"
    if write {
      request.httpBody = Self.formBody(params)
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://message.bilibili.com/", forHTTPHeaderField: "Referer")
    request.setValue(
      cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw BiliError(text: "消息连接失败，请重试")
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let code = root["code"] as? Int
    else { throw BiliError(text: "消息数据无效") }
    guard code == 0 else {
      throw BiliError(
        text: "\(root["message"] as? String ?? root["msg"] as? String ?? "消息请求失败")（\(code)）")
    }
    return root["data"] as? [String: Any] ?? ["items": root["data"] as? [Any] ?? []]
  }
  func nav() async throws -> Account? {
    let generation = authenticationGeneration
    let pending: Task<[String: Any], Error>
    let requestID: UUID
    if let navigationTask { pending = navigationTask.task; requestID = navigationTask.id }
    else {
      pending = Task { try await request("/x/web-interface/nav") }
      requestID = UUID()
      navigationTask = (requestID, pending)
    }
    defer { if navigationTask?.id == requestID { navigationTask = nil } }
    let data = try await pending.value
    guard generation == authenticationGeneration else { throw CancellationError() }
    if let wbi = data["wbi_img"] as? [String: String], let a = wbi["img_url"],
      let b = wbi["sub_url"], let imageURL = URL(string: a), let subURL = URL(string: b)
    {
      wbiKey = Self.mixin(
        imageURL.deletingPathExtension().lastPathComponent
          + subURL.deletingPathExtension().lastPathComponent)
    }
    guard let loggedIn = data["isLogin"] as? Bool else {
      throw BiliError(text: "账号状态返回不完整，请稍后重试")
    }
    guard loggedIn else { return nil }
    return Account(
      name: data["uname"] as? String ?? "已登录", mid: data["mid"] as? Int ?? 0,
      face: data["face"] as? String ?? "")
  }
  func popular(page: Int) async throws -> [Video] {
    let d = try await request("/x/web-interface/popular", ["pn": "\(page)", "ps": "24"])
    return (d["list"] as? [[String: Any]] ?? []).compactMap(Video.parse)
  }
  func search(_ term: String, page: Int, options: SearchOptions = SearchOptions()) async throws -> [Video] {
    let d = try await request(
      "/x/web-interface/wbi/search/type",
      ["search_type": "video", "keyword": term, "page": "\(page)", "page_size": "24"].merging(options.parameters) { _, new in new }, signed: true)
    return (d["result"] as? [[String: Any]] ?? []).compactMap(Video.parse)
  }
  func detail(_ bvid: String) async throws -> Detail {
    let d = try await request("/x/web-interface/wbi/view", ["bvid": bvid], signed: true)
    guard let video = Video.parse(d) else { throw BiliError(text: "视频不可用") }
    return Detail(
      video: video, description: d["desc"] as? String ?? "",
      pages: (d["pages"] as? [[String: Any]] ?? []).compactMap { p in
        guard let cid = p["cid"] as? Int else { return nil }
        return Page(id: cid, title: p["part"] as? String ?? "正片", number: p["page"] as? Int ?? 1, duration: p["duration"] as? Int ?? 0)
      }, aid: d["aid"] as? Int ?? 0, ownerID: (d["owner"] as? [String: Any])?["mid"] as? Int ?? 0,
      ownerFace: (d["owner"] as? [String: Any])?["face"] as? String ?? "",
      copyright: d["copyright"] as? Int ?? 1,
      counts: VideoCounts(d["stat"] as? [String: Any] ?? [:]), collection: VideoCollection.parse(d["ugc_season"]))
  }
  func streams(bvid: String, cid: Int, quality: Int = 127) async throws -> Streams {
    let d = try await request(
      "/x/player/playurl",
      [
        "bvid": bvid, "cid": "\(cid)", "qn": "\(quality)", "fnval": "4048",
        "web_location": "1315873", "gaia_source": "pre-load", "isGaiaAvoided": "true",
        "try_look": signedIn ? "0" : "1", "fourk": "1",
        "fnver": "0",
      ])
    return try Self.parseStreams(d)
  }
  static func parseStreams(_ d: [String: Any]) throws -> Streams {
    guard let dash = d["dash"] as? [String: Any] else { throw BiliError(text: "没有可播放的媒体，请登录后重试") }
    var diagnostics: [String: String] = [:]
    func parse(_ rows: [[String: Any]], kind: MediaKind) -> [MediaRepresentation] {
      var result: [MediaRepresentation] = []
      for (index, row) in rows.enumerated() {
        // Only URL origins and fixed reason codes. Never retain query signatures,
        // paths, cookies or the complete playurl response in diagnostics.
        let origins = mediaAddressStrings(row).prefix(8).map(mediaOrigin).joined(separator: ",")
        let outcome: String
        do {
          let representation = try representation(row, kind: kind)
          result.append(representation)
          outcome = "ok; usable=\(representation.urlCandidates.count)"
        } catch {
          outcome = (error as? MediaRepresentationFailure)?.rawValue ?? "attributes"
        }
        diagnostics["manifest.\(kind.rawValue).\(index)"] =
          "quality=\(row["id"] as? Int ?? 0); \(outcome); sources=\(origins)"
      }
      return result
    }
    let videoRows = (dash["video"] as? [[String: Any]] ?? []).filter { item in
      let codec = item["codecs"] as? String ?? ""
      return codec.hasPrefix("avc1") || codec.hasPrefix("hvc1") || codec.hasPrefix("hev1")
        || codec.hasPrefix("dvh1") || codec.hasPrefix("dvhe")
        || (codec.hasPrefix("av01") && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
    }
    let audioRows = (dash["audio"] as? [[String: Any]] ?? []).filter {
      ($0["codecs"] as? String ?? "").hasPrefix("mp4a")
    }
    let videos = parse(videoRows, kind: .video)
    let audios = parse(audioRows, kind: .audio)
    diagnostics["manifest.video.available"] = "\(videos.count)/\(videoRows.count)"
    diagnostics["manifest.audio.available"] = "\(audios.count)/\(audioRows.count)"
    guard !videos.isEmpty else { throw StreamManifestError(kind: "video", diagnostics: diagnostics) }
    guard let audio = audios.max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) })
    else { throw StreamManifestError(kind: "audio", diagnostics: diagnostics) }
    var names: [Int: String] = [:]
    for f in d["support_formats"] as? [[String: Any]] ?? [] {
      if let id = f["quality"] as? Int {
        names[id] = f["new_description"] as? String ?? f["display_desc"] as? String
      }
    }
    return Streams(videos: videos.sorted { $0.id > $1.id }, audio: audio, names: names, diagnostics: diagnostics)
  }
  private static func mediaAddressStrings(_ j: [String: Any]) -> [String] {
    [j["baseUrl"] as? String, j["base_url"] as? String].compactMap { $0 }
      + (j["backupUrl"] as? [String] ?? []) + (j["backup_url"] as? [String] ?? [])
  }
  private static func mediaOrigin(_ raw: String) -> String {
    guard let parts = URLComponents(string: raw.hasPrefix("//") ? "https:" + raw : raw),
      let host = parts.host, host.count <= 253,
      host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]").contains($0) })
    else { return "invalid" }
    let scheme = ["http", "https"].contains(parts.scheme?.lowercased() ?? "") ? parts.scheme!.lowercased() : "other"
    return scheme + "://" + host + (parts.port.map { ":\($0)" } ?? "")
  }
  private static func representation(_ j: [String: Any], kind: MediaKind) throws -> MediaRepresentation {
    var seen = Set<URL>()
    let candidates = mediaAddressStrings(j).compactMap { BiliMediaCDNURLPolicy().normalizedURL($0) }
      .filter { seen.insert($0).inserted }
    // A rejected primary must not hide the same representation's valid backups.
    guard let url = candidates.first else { throw MediaRepresentationFailure.address }
    guard let seg = j["SegmentBase"] as? [String: Any] ?? j["segment_base"] as? [String: Any]
      ?? j["segmentBase"] as? [String: Any] else { throw MediaRepresentationFailure.segmentBase }
    func range(_ raw: String?) throws -> MediaByteRange {
      let p = (raw ?? "").split(separator: "-", omittingEmptySubsequences: false)
      guard p.count == 2, p.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
        let start = Int64(p[0]), let end = Int64(p[1]), end >= start, end < Int64.max
      else { throw MediaRepresentationFailure.byteRange }
      return try MediaByteRange(start: start, endInclusive: end)
    }
    let attrs: VideoRepresentationAttributes? =
      kind == .video
      ? try VideoRepresentationAttributes(
        width: j["width"] as? Int ?? 0, height: j["height"] as? Int ?? 0,
        frameRate: Self.frameRate(j["frameRate"] as? String ?? j["frame_rate"] as? String),
        dynamicRange: Self.dynamicRange(j)) : nil
    return MediaRepresentation(
      id: j["id"] as? Int ?? 0, kind: kind, codecs: j["codecs"] as? String ?? "",
      mimeType: j["mimeType"] as? String ?? j["mime_type"] as? String ?? "video/mp4",
      bandwidth: j["bandwidth"] as? Int, videoAttributes: attrs, primaryURL: url,
      backupURLs: Array(candidates.dropFirst()),
      segmentBase: SegmentBase(
        initialization: try range(seg["Initialization"] as? String ?? seg["initialization"] as? String),
        index: try range(seg["indexRange"] as? String ?? seg["index_range"] as? String)))
  }
  static func frameRate(_ raw: String?) -> Double? {
    guard let raw else { return nil }
    let parts = raw.split(separator: "/").compactMap { Double($0) }
    if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
    return parts.count == 1 ? parts[0] : nil
  }
  static func dynamicRange(_ j: [String: Any]) -> VideoDynamicRange {
    let transfer = j["color_transfer"] as? Int ?? j["transfer_characteristics"] as? Int
    if transfer == 18 { return .hlg }
    if transfer == 16 || [125, 126].contains(j["id"] as? Int ?? 0) { return .pq }
    return .sdr
  }
  static func videoCandidates(_ videos: [MediaRepresentation], quality: Int,
    preference: VideoCodecPreference? = nil) -> [MediaRepresentation] {
    let candidates = videos.filter { $0.id == quality }
    let choice = preference ?? VideoCodecPreference(rawValue: UserDefaults.standard.string(forKey: "videoCodecPreference") ?? "auto") ?? .automatic
    let order = choice == .av1 || (choice == .automatic && quality == 127)
      ? ["av1", "hevc", "h264"] : choice == .hevc ? ["hevc", "av1", "h264"] : ["hevc", "h264", "av1"]
    func rank(_ codec: String) -> Int {
      let family = codec.hasPrefix("av01") ? "av1" :
        ["hvc1", "hev1", "dvh1", "dvhe"].contains(String(codec.prefix(4))) ? "hevc" :
        codec.hasPrefix("avc1") ? "h264" : "unknown"
      return order.firstIndex(of: family) ?? order.count
    }
    return candidates.enumerated().sorted {
      let a = rank($0.element.codecs), b = rank($1.element.codecs)
      return a == b ? $0.offset < $1.offset : a < b
    }.map(\.element)
  }
  static func bestVideo(_ videos: [MediaRepresentation], quality: Int,
    preference: VideoCodecPreference? = nil) -> MediaRepresentation? {
    videoCandidates(videos, quality: quality, preference: preference).first
  }
  static func mixin(_ key: String) -> String {
    let table = [
      46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29,
      28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22,
      25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
    ]
    let a = Array(key)
    return String(table.compactMap { $0 < a.count ? a[$0] : nil }.prefix(32))
  }
  static func sign(
    _ query: [String: String], key: String, timestamp: Int = Int(Date().timeIntervalSince1970)
  ) -> [String: String] {
    var p = query.mapValues { $0.filter { !"!'()*".contains($0) } }
    p["wts"] = "\(timestamp)"
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    let joined = p.sorted { $0.key < $1.key }.map {
      "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
    }.joined(separator: "&")
    p["w_rid"] = Insecure.MD5.hash(data: Data((joined + key).utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    return p
  }
}
