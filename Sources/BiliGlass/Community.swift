import Foundation
import SwiftUI

struct Reply: Identifiable {
  let id: Int
  let mid: Int
  let name: String
  let face: String
  let message: String
  let date: Date
  let location: String
  var likes: Int
  var count: Int
  let root: Int
  var liked: Bool
  var children: [Reply]
  let pictures: [String]
  let textContent: CommentTextContent
  let videoLinks: [CommentVideoLink]
  static func deduplicated(_ replies: [Reply], excluding: Set<Int> = []) -> [Reply] {
    var ids = excluding
    return replies.filter { ids.insert($0.id).inserted }
  }
  static func parse(_ j: [String: Any]) -> Reply? {
    guard let id = j["rpid"] as? Int else { return nil }
    let member = j["member"] as? [String: Any] ?? [:]
    let content = j["content"] as? [String: Any] ?? [:]
    let control = j["reply_control"] as? [String: Any] ?? [:]
    return Reply(
      id: id, mid: Int(member["mid"] as? String ?? "") ?? member["mid"] as? Int ?? 0,
      name: member["uname"] as? String ?? "用户", face: member["avatar"] as? String ?? "",
      message: content["message"] as? String ?? "",
      date: Date(timeIntervalSince1970: j["ctime"] as? Double ?? 0),
      location: control["location"] as? String ?? "", likes: j["like"] as? Int ?? 0,
      count: j["rcount"] as? Int ?? 0, root: j["root"] as? Int ?? 0,
      liked: j["action"] as? Int == 1,
      children: deduplicated((j["replies"] as? [[String: Any]] ?? []).compactMap(Reply.parse)),
      pictures: (content["pictures"] as? [[String: Any]] ?? []).compactMap {
        $0["img_src"] as? String
      },
      textContent: CommentTextContent(message: content["message"] as? String ?? "",
        emotes: CommentEmote.parse(content["emote"])),
      videoLinks: CommentVideoLink.parse(message: content["message"] as? String ?? "",
        jumps: content["jump_url"]))
  }
}
struct Profile {
  let mid: Int
  let name: String
  let face: String
  let bio: String
  let fans: Int
  let following: Int
  let videos: Int
  var isFollowed: Bool
}
struct FavoriteFolder: Identifiable, Hashable {
  let id: Int
  let title: String
  let count: Int
  var containsVideo = false
  var isPrivate = false
  // attr bit 0 is privacy; bit 1 identifies a non-default folder.
  static func privacyIsPrivate(_ attributes: Int) -> Bool { attributes & 1 != 0 }
}

extension API {
  nonisolated static func formBody(_ values: [String: String]) -> Data {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return Data(
      values.sorted { $0.key < $1.key }.map {
        "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
      }.joined(separator: "&").utf8)
  }
  func post(_ path: String, _ values: [String: String], videoBVID: String? = nil) async throws -> [String: Any] {
    try Task.checkCancellation()
    let allowed = [
      "/x/v2/reply/add", "/x/v2/reply/action", "/x/v2/reply/del", "/x/v2/dm/post",
      "/x/web-interface/archive/like", "/x/web-interface/archive/like/triple", "/x/web-interface/coin/add", "/x/v3/fav/resource/deal",
      "/x/v2/history/toview/add", "/x/v2/history/toview/del", "/x/v2/history/report", "/x/relation/modify",
      "/x/v3/fav/folder/add",
      "/x/v3/fav/folder/edit", "/x/v3/fav/folder/del",
      "/x/web-interface/feedback/dislike", "/x/web-interface/feedback/dislike/cancel", "/x/web-interface/appeal/v2/submit",
      "/x/dm/filter/user/add", "/x/dm/filter/user/del", "/x/dm/report/add",
      "/pgc/web/follow/add", "/pgc/web/follow/del",
    ]
    guard allowed.contains(path), signedIn, let csrf = cookies["bili_jct"] else {
      throw BiliError(text: "请先登录")
    }
    let auth = authenticationGeneration
    var body = values
    body["csrf"] = csrf
    let originalBody = body
    var url = URLComponents(string: "https://api.bilibili.com" + path)!
    if let grant = consumeVerification(path: path, body: body) {
      url.queryItems = [URLQueryItem(name: "gaia_vtoken", value: grant.token)]
      if grant.challenge.code == -401 {
        url.queryItems?.append(URLQueryItem(name: "token", value: grant.token))
        body["tk"] = grant.token
      }
    }
    var req = URLRequest(url: url.url!)
    req.httpMethod = "POST"
    req.httpBody = Self.formBody(body)
    req.setValue(
      "application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    req.setValue(
      cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
    Self.mediaHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
    if let videoBVID, videoID(videoBVID) == videoBVID {
      req.setValue("https://www.bilibili.com/video/\(videoBVID)/", forHTTPHeaderField: "Referer")
    }
    let (data, r) = try await session.data(for: req)
    try Task.checkCancellation()
    guard auth == authenticationGeneration else { throw CancellationError() }
    guard (r as? HTTPURLResponse)?.statusCode == 200,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw BiliError(text: "发送失败，请稍后重试") }
    guard root["code"] as? Int == 0 else {
      let challenge = (r as? HTTPURLResponse).flatMap {
        InteractionChallenge.parse(root, response: $0, path: path, body: originalBody, authentication: auth)
      }
      throw BiliError(text: root["message"] as? String ?? "操作失败", code: root["code"] as? Int, challenge: challenge)
    }
    let d = root["data"] as? [String: Any] ?? [:]
    if d["need_captcha"] as? Bool == true { throw BiliError(text: "需要完成官方验证", code: -352) }
    return d
  }
  func binary(_ path: String, _ query: [String: String]) async throws -> Data {
    guard ["/x/v2/dm/web/seg.so", "/x/v2/dm/web/view", "/x/v2/dm/web/history/seg.so"].contains(path) else {
      throw BiliError(text: "请求无效")
    }
    var u = URLComponents(string: "https://api.bilibili.com" + path)!
    u.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    var req = URLRequest(url: u.url!)
    Self.mediaHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    req.setValue(
      cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
    let (data, r) = try await session.data(for: req)
    guard (r as? HTTPURLResponse)?.statusCode == 200, data.count < 32 * 1024 * 1024,
      (r.mimeType ?? "").contains("octet-stream")
    else { throw BiliError(text: "弹幕加载失败") }
    return data
  }
  func recommendations(page: Int) async throws -> [Video] {
    let d = try await request(
      "/x/web-interface/wbi/index/top/feed/rcmd",
      [
        "ps": "24", "fresh_idx": "\(page)", "fresh_idx_1h": "\(page)", "fresh_type": "3",
        "feed_version": "V8", "homepage_ver": "1", "brush": "0", "y_num": "4",
      ], signed: true)
    return (d["item"] as? [[String: Any]] ?? []).compactMap(Video.parse)
  }
  func profile(_ mid: Int) async throws -> Profile {
    let d = try await request("/x/web-interface/card", ["mid": "\(mid)", "photo": "true"])
    let c = d["card"] as? [String: Any] ?? [:]
    return Profile(
      mid: mid, name: c["name"] as? String ?? "用户", face: c["face"] as? String ?? "",
      bio: c["sign"] as? String ?? "", fans: c["fans"] as? Int ?? 0,
      following: c["attention"] as? Int ?? 0, videos: d["archive_count"] as? Int ?? 0,
      isFollowed: d["following"] as? Bool ?? false)
  }
  func profileVideos(_ mid: Int, page: Int) async throws -> [Video] {
    let d = try await request(
      "/x/space/wbi/arc/search",
      [
        "mid": "\(mid)", "pn": "\(page)", "ps": "30", "order": "pubdate", "platform": "web",
        "web_location": "1550101",
      ], signed: true)
    return ((d["list"] as? [String: Any])?["vlist"] as? [[String: Any]] ?? []).compactMap(
      Video.parse)
  }
  func favoriteFolders(_ mid: Int, aid: Int? = nil) async throws -> [FavoriteFolder] {
    var query = ["up_mid": "\(mid)"]
    if let aid { query["rid"] = String(aid); query["type"] = "2" }
    let d = try await request("/x/v3/fav/folder/created/list-all", query)
    return (d["list"] as? [[String: Any]] ?? []).compactMap { j in
      guard let id = j["id"] as? Int else { return nil }
      return FavoriteFolder(
        id: id, title: j["title"] as? String ?? "收藏夹", count: j["media_count"] as? Int ?? 0,
        containsVideo: (j["fav_state"] as? Int ?? 0) == 1,
        isPrivate: FavoriteFolder.privacyIsPrivate(j["attr"] as? Int ?? 0))
    }
  }
  func favorites(_ folder: Int, page: Int, keyword: String = "") async throws -> [Video] {
    let d = try await request(
      "/x/v3/fav/resource/list",
      ["media_id": "\(folder)", "pn": "\(page)", "ps": "20", "order": "mtime", "platform": "web", "keyword": keyword])
    return (d["medias"] as? [[String: Any]] ?? []).compactMap {
      var j = $0
      j["pic"] = j["cover"]
      j["owner"] = j["upper"]
      return Video.parse(j)
    }
  }
  func later() async throws -> [Video] {
    let d = try await request("/x/v2/history/toview")
    return (d["list"] as? [[String: Any]] ?? []).compactMap(Video.parse)
  }
  func followedVideos(page: Int) async throws -> [Video] {
    if page == 1 {
      dynamicCursor = ""
      dynamicHasMore = true
    }
    var query = ["type": "video"]
    if !dynamicCursor.isEmpty { query["offset"] = dynamicCursor }
    let d = try await request("/x/polymer/web-dynamic/v1/feed/all", query)
    dynamicCursor = d["offset"] as? String ?? ""
    dynamicHasMore = d["has_more"] as? Bool ?? (d["has_more"] as? Int == 1)
    return (d["items"] as? [[String: Any]] ?? []).compactMap { j in
      let modules = j["modules"] as? [String: Any] ?? [:]
      let author = modules["module_author"] as? [String: Any] ?? [:]
      guard
        var v = ((modules["module_dynamic"] as? [String: Any])?["major"] as? [String: Any])?[
          "archive"] as? [String: Any]
      else { return nil }
      v["pic"] = v["cover"]
      v["author"] = author["name"]
      return Video.parse(v)
    }
  }
}

@MainActor @Observable final class Comments {
  var items: [Reply] = []
  var count = 0
  private(set) var hasLoadedCount = false
  var loading = false
  var error: String?
  var resourceType = 1
  var sort = UserDefaults.standard.object(forKey: "commentSort") as? Int ?? 1
  var page = 1
  var hasMore = true
  var draft = ""
  var attachments: [URL] = []
  var replyingTo: Reply?
  var sending = false
  var sendError: String?
  var submittedText: String?
  var submissionStatus: String?
  var focusedRoot: Reply?
  var focusedReplyID: Int?
  var focusedReplies: [Reply] {
    guard let root = focusedRoot else { return [] }
    return (expanded[root.id] ?? root.children).filter { $0.id != focusedReplyID }
  }
  var expanded: [Int: [Reply]] = [:]
  var childPages: [Int: Int] = [:]
  var childLoading: Set<Int> = []
  var childErrors: [Int: String] = [:]
  var childHasMore: [Int: Bool] = [:]
  private var nextOffset: String?
  var paginationDiagnostics: [String: String] = [:]
  private var liking: Set<Int> = []
  private var identity = UUID()
  private var task: Task<Void, Never>?
  private var resourceID: Int?
  private var listIdentity = UUID()
  func loadIfNeeded(aid: Int, type: Int = 1, api: API) {
    guard resourceID != aid || resourceType != type else { return }
    load(aid: aid, type: type, api: api)
  }
  func load(aid: Int, type: Int = 1, api: API, more: Bool = false) {
    if resourceID != aid || resourceType != type {
      stop()
      resourceID = aid
      resourceType = type
    }
    if more && (loading || !hasMore) { return }
    if !more {
      task?.cancel()
      listIdentity = UUID()
      page = 1
      childLoading = []
      childErrors = [:]
      nextOffset = nil
      liking = []
      hasMore = true
    }
    let token = identity
    let listToken = listIdentity
    let next = more ? page + 1 : 1
    let order = sort
    let kind = resourceType
    let offset = more ? nextOffset : nil
    loading = true
    error = nil
    task = Task {
      do {
        let d = try await api.request(
          "/x/v2/reply/wbi/main",
          [
            "type": String(kind), "oid": "\(aid)", "mode": order == 1 ? "3" : "2",
            "pagination_str": try CommentPage.pagination(offset), "web_location": "1315875",
          ], signed: true)
        try Task.checkCancellation()
        guard token == identity, listToken == listIdentity else { return }
        let result = try CommentPage.parse(d, first: !more)
        paginationDiagnostics = ["repeatedCursor": String(result.nextOffset == offset),
          "receivedReplies": String(result.replies.count), "page": String(next)]
        let ids = more ? Set(items.map(\.id)) : []
        let additions = Reply.deduplicated(result.replies, excluding: ids)
        // Account-specific cursors can remain identical across distinct pages.
        // Detect repeated content, not repeated opaque tokens.
        if more && additions.isEmpty && result.nextOffset != nil {
          throw BiliError(text: "本页没有返回新的评论，请重试或切换排序")
        }
        count = result.count
        hasLoadedCount = true
        items = more ? items + additions : additions
        if !more {
          expanded = [:]
          childPages = [:]
          childHasMore = [:]
        }
        page = next
        nextOffset = result.nextOffset
        hasMore = result.nextOffset != nil
        loading = false
      } catch {
        guard token == identity, listToken == listIdentity, !Task.isCancelled else { return }
        loading = false
        self.error = error.localizedDescription
      }
    }
  }
  func children(_ reply: Reply, aid: Int, api: API, pageSize: Int = 10) async {
    guard childHasMore[reply.id] != false else { return }
    guard childLoading.insert(reply.id).inserted else { return }
    let token = identity
    let listToken = listIdentity
    defer { if token == identity && listToken == listIdentity { childLoading.remove(reply.id) } }
    let page = (childPages[reply.id] ?? 0) + 1
    childErrors[reply.id] = nil
    do {
      let d = try await api.request(
        "/x/v2/reply/reply",
        [
          "type": String(resourceType), "oid": "\(aid)", "root": "\(reply.id)", "pn": "\(page)",
          "ps": String(pageSize),
        ])
      guard token == identity, listToken == listIdentity else { return }
      let replies = (d["replies"] as? [[String: Any]] ?? []).compactMap(Reply.parse)
      let old = expanded[reply.id] ?? reply.children
      let ids = Set(old.map(\.id))
      expanded[reply.id] = old + Reply.deduplicated(replies, excluding: ids)
      childPages[reply.id] = page
      let total = (d["page"] as? [String: Any])?["count"] as? Int ?? reply.count
      childHasMore[reply.id] = !replies.isEmpty && page * pageSize < total
    } catch {
      if token == identity && listToken == listIdentity && !Task.isCancelled {
        childErrors[reply.id] = error.localizedDescription
      }
    }
  }
  func loadFocused(_ target: NoticeCommentTarget, api: API) async -> Reply? {
    stop()
    resourceID = target.oid
    resourceType = target.type
    let token = identity
    loading = true
    defer { if token == identity { loading = false } }
    do {
      let data = try await api.request("/x/v2/reply/wbi/main", [
        "oid": String(target.oid), "type": String(target.type), "mode": "3",
        "seek_rpid": String(target.replyID), "pagination_str": try CommentPage.pagination(nil),
        "web_location": "1315875"
      ], signed: true)
      try Task.checkCancellation()
      guard token == identity else { return nil }
      var roots = (data["replies"] as? [[String: Any]] ?? []).compactMap(Reply.parse)
      roots += (data["top_replies"] as? [[String: Any]] ?? []).compactMap(Reply.parse)
      func find(_ rows: [Reply]) -> Reply? {
        for row in rows {
          if row.id == target.replyID { return row }
          if let child = find(row.children) { return child }
        }
        return nil
      }
      var focused = find(roots)
      let rootID = focused.map { $0.root == 0 ? $0.id : $0.root } ?? target.rootID
      if rootID > 0 {
        do {
          let thread = try await api.request("/x/v2/reply/reply", [
            "oid": String(target.oid), "type": String(target.type), "root": String(rootID),
            "pn": "1", "ps": "49"
          ])
          try Task.checkCancellation()
          guard token == identity else { return nil }
          let children = (thread["replies"] as? [[String: Any]] ?? []).compactMap(Reply.parse)
          focused = focused ?? find(children)
          if let root = (thread["root"] as? [String: Any]).flatMap(Reply.parse) {
            focusedRoot = root
            if focused == nil, root.id == target.replyID { focused = root }
          }
          let total = (thread["page"] as? [String: Any])?["count"] as? Int
            ?? focusedRoot?.count ?? roots.first(where: { $0.id == rootID })?.count ?? children.count
          focusedRoot = focusedRoot ?? roots.first(where: { $0.id == rootID })
            ?? Reply.parse(["rpid": rootID, "rcount": total])
          expanded[rootID] = Reply.deduplicated(children)
          childPages[rootID] = 1
          childHasMore[rootID] = !children.isEmpty && children.count < total
        } catch {
          try Task.checkCancellation()
          guard token == identity else { return nil }
          if focused == nil { throw error }
          focusedRoot = roots.first(where: { $0.id == rootID }) ?? Reply.parse(["rpid": rootID])
          childErrors[rootID] = error.localizedDescription
        }
      }
      guard let focused else { throw BiliError(text: "未能定位这条评论，可能已删除或暂不可见。可重试或查看原页面。") }
      // Keep the exact requested reply visible even if the server omits its parent in the seek response.
      items = [focused]
      focusedReplyID = focused.id
      hasMore = false
      return focused
    } catch {
      if token == identity && !Task.isCancelled { self.error = error.localizedDescription }
      return nil
    }
  }
  func collapse(_ reply: Reply) {
    guard !childLoading.contains(reply.id) else { return }
    expanded[reply.id] = nil; childPages[reply.id] = nil
    childHasMore[reply.id] = nil; childErrors[reply.id] = nil
  }
  func send(aid: Int, api: API) async {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sending, (!text.isEmpty || !attachments.isEmpty), text.count <= 1000 else { return }
    let token = identity
    let target = replyingTo
    sending = true
    sendError = nil
    submittedText = nil
    submissionStatus = nil
    defer { if token == identity { sending = false } }
    do {
      var body = ["type": String(resourceType), "oid": "\(aid)", "message": text, "plat": "1"]
      if !attachments.isEmpty {
        var pictures: [[String: Any]] = []
        for url in attachments { pictures.append(try await api.uploadImage(url, business: "new_dyn").commentPayload) }
        guard token == identity else { return }
        body["pictures"] = String(decoding: try JSONSerialization.data(withJSONObject: pictures), as: UTF8.self)
      }
      if let target {
        body["root"] = "\(target.root == 0 ? target.id : target.root)"
        body["parent"] = "\(target.id)"
      }
      let result = try await api.post("/x/v2/reply/add", body)
      guard token == identity else { return }
      draft = ""
      attachments = []
      replyingTo = nil
      submittedText = text
      let toast = result["success_toast"] as? String ?? ""
      submissionStatus = toast.isEmpty ? "服务器已接收" : toast
      if let raw = result["reply"] as? [String: Any], let reply = Reply.parse(raw) {
        if let target {
          let root = target.root == 0 ? target.id : target.root
          let existing = expanded[root] ?? items.first(where: { $0.id == root })?.children ?? []
          expanded[root] = Reply.deduplicated(existing + [reply])
          if let index = items.firstIndex(where: { $0.id == root }) {
            items[index].count = max(items[index].count + 1, expanded[root]?.count ?? 0)
            items[index].children = Reply.deduplicated(items[index].children + [reply])
          }
        } else {
          items = Reply.deduplicated([reply] + items)
          count += 1
        }
      } else {
        submissionStatus = (toast.isEmpty ? "服务器已接收" : toast) + "，尚未返回评论内容，请稍后刷新确认"
      }
    } catch {
      guard token == identity else { return }
      sendError = error.localizedDescription
    }
  }
  func like(_ reply: Reply, aid: Int, api: API) async {
    guard liking.insert(reply.id).inserted else { return }
    let token = identity
    defer { if token == identity { liking.remove(reply.id) } }
    do {
      _ = try await api.post(
        "/x/v2/reply/action",
        [
          "type": String(resourceType), "oid": "\(aid)", "rpid": "\(reply.id)",
          "action": reply.liked ? "0" : "1",
        ])
      guard token == identity else { return }
      func updated(_ row: Reply) -> Reply {
        var row = row
        if row.id == reply.id {
          row.liked = !reply.liked
          row.likes = max(0, reply.likes + (reply.liked ? -1 : 1))
        }
        row.children = row.children.map { child in
          var child = child
          if child.id == reply.id {
            child.liked = !reply.liked
            child.likes = max(0, reply.likes + (reply.liked ? -1 : 1))
          }
          return child
        }
        return row
      }
      items = items.map(updated)
      expanded = expanded.mapValues { $0.map(updated) }
    } catch { if token == identity { sendError = error.localizedDescription } }
  }
  func stop() {
    task?.cancel()
    identity = UUID()
    listIdentity = UUID()
    resourceID = nil
    items = []
    expanded = [:]
    childPages = [:]
    childLoading = []
    liking = []
    draft = ""
    attachments = []
    replyingTo = nil
    error = nil
    sendError = nil
    submittedText = nil
    submissionStatus = nil
    focusedRoot = nil
    focusedReplyID = nil
    loading = false
    sending = false
    count = 0
    hasLoadedCount = false
    page = 1
    hasMore = true
    childErrors = [:]
    childHasMore = [:]
    nextOffset = nil
    paginationDiagnostics = [:]
  }
}
