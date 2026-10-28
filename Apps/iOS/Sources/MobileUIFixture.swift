#if DEBUG
  import Foundation
  import UIKit

  /// Synthetic UI scenarios. This session intercepts every request; no real account is read or written.
  final class MobileUIFixture: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var feedLoads: [String: Int] = [:]
    private static var readKinds: Set<String> = []
    private static var failed = false
    private static var loginPollFailed = false
    private static var qrRequests = 0
    private static var coins = ProcessInfo.processInfo.arguments.contains("--qa-coins-full") ? 2 : 0
    private static var liked = false
    private static var favorited = false
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--qa-ui") }
    static var sessionRestorationEnabled: Bool {
      ProcessInfo.processInfo.arguments.contains("--qa-session-restoration")
    }
    @MainActor static func makeSessionAPI() -> API {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [MobileUIFixture.self]
      // Exercise real Keychain persistence without reading or replacing a real login.
      let api = API(loadCredentials: false, transport: URLSession(configuration: configuration),
        credentialAccount: "qa-session-restoration")
      if ProcessInfo.processInfo.arguments.contains("--qa-session-seed") {
        try! api.saveClientLogin(StoredLogin(
          cookies: ["SESSDATA": "fixture", "bili_jct": "fixture", "DedeUserID": "1"],
          appCoinAuthorization: .init(accountID: 1, accessToken: "local-app-fixture", expires: .distantFuture)))
      }
      return api
    }
    static var empty: Bool { ProcessInfo.processInfo.arguments.contains("--qa-ui-empty") }
    @MainActor static func makeAPI() -> API {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [MobileUIFixture.self]
      let api = API(loadCredentials: false, transport: URLSession(configuration: configuration))
      api.cookies = ["SESSDATA": "fixture", "bili_jct": "fixture", "DedeUserID": "1"]
      if ProcessInfo.processInfo.arguments.contains("--qa-app-coins") {
        api.appCoinAuthorization = .init(accountID: 1, accessToken: "local-app-fixture",
          expires: ProcessInfo.processInfo.arguments.contains("--qa-token-expired") ? .distantPast : .distantFuture)
      }
      return api
    }
    @MainActor static func openVideo(_ visit: MobileVideoVisit, store: Store) {
      store.playback.stop()
      let first = visit.bvid == "BV1xx411c7mD"
      store.playback.detail = Detail(
        video: Video(
          bvid: visit.bvid,
          title: first ? "导航测试视频 A" : "导航测试视频 B", cover: "", author: "导航测试 UP 主",
          duration: 180, views: 100), description: "用于检查逐层返回、评论草稿和阅读位置。",
        pages: [], aid: first ? 123 : 456, ownerID: 11,
        copyright: ProcessInfo.processInfo.arguments.contains("--qa-repost") ? 2 : 1)
      if ProcessInfo.processInfo.arguments.contains("--qa-sequences") {
        let video = store.playback.detail!.video
        store.playback.detail = Detail(video: video, description: "分 P 与合集同时存在的测试视频",
          pages: [Page(id: 101, title: "第一部分", number: 1), Page(id: 102, title: "第二部分", number: 2)], aid: 123, ownerID: 11,
          collection: VideoCollection(title: "测试合集", items: [
            PlaybackQueueItem(bvid: visit.bvid, cid: 101, title: "当前视频"),
            PlaybackQueueItem(bvid: "BV1yy411c7mD", cid: 201, title: "合集下一视频")]))
      }
      store.playback.selectedCID = ProcessInfo.processInfo.arguments.contains("--qa-sequences") ? 101 : 0
      store.playback.positionSeconds = visit.resume?.position ?? 42
      store.playback.isPlaying = false
    }
    @MainActor static var image: UIImage {
      UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { context in
        UIColor.systemBlue.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        UIColor.systemPink.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        UIColor.systemYellow.setFill()
        context.fill(CGRect(x: 600, y: 400, width: 600, height: 400))
      }
    }
    @MainActor static func captureInterface() {
      guard enabled || ProcessInfo.processInfo.arguments.contains("--qa-capture"),
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
        let window = scene.windows.first(where: \.isKeyWindow)
      else { return }
      let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
      }
      let folder = AppPaths.support.appendingPathComponent("QA")
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try? image.pngData()?.write(
        to: folder.appendingPathComponent("interface.png"), options: .atomic)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      Self.lock.lock()
      defer { Self.lock.unlock() }
      let path = request.url?.path ?? ""
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let system = query.contains { $0.name == "session_type" && $0.value == "7" }
      let populated = ProcessInfo.processInfo.arguments.contains("--qa-ui-pages")
      let retention = ProcessInfo.processInfo.arguments.contains("--qa-feed-retention")
      let page = Int(query.first { ["fresh_idx", "pn", "display_id"].contains($0.name) }?.value ?? "1") ?? 1
      let feedKey = path + (query.first { $0.name == "from_region" }?.value ?? "")
      if retention && page == 1 { Self.feedLoads[feedKey, default: 0] += 1 }
      let generation = Self.feedLoads[feedKey, default: 1]
      let count = retention ? 24 : 6
      let videos: [[String: Any]] = (1...count).map { rawIndex in
        let index = rawIndex + (retention ? (page - 1) * count : 0)
        return [
          "bvid": index == 1 ? "BV1xx411c7mD" : "BV1yy411c7mD\(index)",
          "title": retention ? "浏览测试 \(index) · 刷新 \(generation)" : index == 1 ? "一条很长的视频标题，用于检查多行截断、封面和上下间距" : "界面测试视频 \(index)",
          "owner": ["name": "测试 UP 主"], "duration": 180, "pic": "",
        ]
      }
      var data: [String: Any] = [:]
      var code = 0
      var message = ""
      if path == "/x/frontend/finger/spi" {
        data = ["b_3": "local-device-fixture", "b_4": "local-device-fixture-4"]
      } else if path == "/x/passport-tv-login/qrcode/auth_code" {
        Self.qrRequests += 1
        data = ["auth_code": "local-qr-fixture", "url": "https://passport.bilibili.com/fixture"]
      } else if path == "/x/passport-tv-login/qrcode/poll" {
        if ProcessInfo.processInfo.arguments.contains("--qa-login-network-loss") {
          if !Self.loginPollFailed {
            Self.loginPollFailed = true
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
          }
          if Self.qrRequests > 1 {
            code = 86038; message = "测试失败：返回前台不应替换原二维码"
          } else { code = 86039 }
        } else { code = 86039 } // Never persist a synthetic login to Keychain.
      } else if path == "/x/web-interface/archive/relation" {
        data = ["like": Self.liked, "coin": Self.coins, "favorite": Self.favorited]
      } else if path == "/x/v2/view/coin/add" || path == "/x/v2/view/like/triple" {
        if ProcessInfo.processInfo.arguments.contains("--qa-coin-timeout") {
          client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        if ProcessInfo.processInfo.arguments.contains("--qa-coin-error") {
          code = -101; message = "请重新登录后再试"
        } else {
          if path.hasSuffix("triple") { Self.coins = 2; Self.liked = true; Self.favorited = true }
          else { Self.coins = min(2, Self.coins + 1) }
          data = ["like": Self.liked]
        }
      } else if path == "/x/web-interface/archive/like" {
        Self.liked.toggle()
      } else if path == "/x/web-interface/coin/add" || path == "/x/web-interface/archive/like/triple" {
        code = -401; message = "测试要求使用客户端授权"
      } else if populated && path == "/x/web-interface/wbi/index/top/feed/rcmd" {
        data = ["item": videos]
      } else if populated && (path == "/x/web-interface/popular" || path == "/x/v2/history/toview")
      {
        data = ["list": videos]
      } else if populated && path == "/x/web-interface/region/feed/rcmd" {
        data = ["archives": videos]
      } else if path == "/x/web-interface/card" {
        data = [
          "card": ["mid": 11, "name": "导航测试 UP 主", "sign": "这是用于界面检查的测试个人主页"], "archive_count": 1,
        ]
      } else if path == "/x/space/wbi/arc/search" {
        data = [
          "list": [
            "vlist": [
              ["bvid": "BV1yy411c7mD", "title": "导航测试视频 B", "author": "导航测试 UP 主", "duration": 180]
            ]
          ]
        ]
      } else if path == "/x/emote/user/panel/web" {
        data = ["packages": (1...2).map { group in
          ["id": group, "text": "表情组 \(group)", "emote": (1...60).map { index in
            ["text": "[组\(group)-\(index)]", "url": "https://i0.hdslb.com/fixture-\(group)-\(index).png"]
          }] as [String: Any]
        }]
      } else if path == "/x/v2/reply/add" {
        data = ["success_toast": "回复成功", "reply": ["rpid": 2, "root": 1,
          "member": ["mid": "1", "uname": "本地测试"], "content": ["message": "通知回复测试"], "ctime": 1_790_000_001]]
      } else if path == "/x/v2/reply/reply" {
        data = ["root": ["rpid": 1], "replies": [], "page": ["count": 0]]
      } else if path.hasPrefix("/x/v2/reply") {
        data = [
          "cursor": ["is_end": true, "all_count": 1],
          "replies": [
            [
              "rpid": 1, "member": ["mid": "11", "uname": "导航测试 UP 主"],
              "content": ["message": "可以实现一层一层返回吗？"], "ctime": 1_790_000_000,
            ]
          ],
        ]
      } else if path.hasSuffix("get_sessions") {
        if ProcessInfo.processInfo.arguments.contains("--qa-ui-error") && !Self.failed {
          Self.failed = true
          client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
          return
        }
        var entries: [[String: Any]] = []
        for index in 1...(system ? 2 : 8) {
          let timestamp = 1_790_000_000 - index * 3600
          let name: String
          if system {
            name = "系统通知 \(index)"
          } else if index == 1 {
            name = "很长的会话名称也需要正确对齐与换行"
          } else {
            name = "测试会话 \(index)"
          }
          let last: [String: Any] = [
            "msg_key": String(index), "msg_type": 1,
            "msg_seqno": String(index), "timestamp": timestamp,
            "content": "{\"content\":\"这是一条用于检查间距和截断的本地示例消息。\"}",
          ]
          let entry: [String: Any] = [
            "talker_id": index + (system ? 100 : 10),
            "session_type": system ? 7 : 1, "session_ts": Int64(timestamp) * 1_000_000,
            "unread_count": index == 1 ? 105 : index == 3 ? 2 : 0,
            "account_info": ["name": name], "last_msg": last,
          ]
          entries.append(entry)
        }
        data = ["session_list": Self.empty ? [] : entries, "has_more": 0]
      } else if path == "/x/msgfeed/unread" {
        data = ["reply": Self.empty || Self.readKinds.contains("reply") ? 0 : 4,
          "at": Self.empty || Self.readKinds.contains("at") ? 0 : 2,
          "like": Self.empty || Self.readKinds.contains("like") ? 0 : 12]
      } else if path.hasSuffix("single_unread") {
        data = ["follow_unread": Self.empty ? 0 : 122, "unfollow_unread": 0]
      } else if path == "/x/msgfeed/like" {
        Self.readKinds.insert("like")
        data = ["total": ["cursor": ["is_end": true], "items": Self.empty ? [] : [
          ["id": 100, "counts": 12, "like_time": 1_790_000_000,
            "users": [["mid": 11, "nickname": "示例用户"]],
            "item": ["business": "视频", "title": "我发布的视频标题", "uri": "https://www.bilibili.com/video/BV1xx411c7mD/"]],
          ["id": 101, "counts": 1, "like_time": 1_790_000_000,
            "users": [["mid": 12, "nickname": "另一位用户"]],
            "item": ["business": "评论", "title": "这里是我发表的评论。"]]
        ]]]
      } else if path.hasPrefix("/x/msgfeed/") {
        Self.readKinds.insert(String(path.split(separator: "/").last ?? ""))
        data = [
          "items": Self.empty
            ? []
            : [
              [
                "id": 1, "reply_time": 1_790_000_000,
                "user": ["mid": 11, "nickname": "示例用户"],
                "item": [
                  "subject_id": 123, "source_id": 1, "root_id": 0, "business_id": 1,
                  "source_content": "这是一条本地互动通知，展示回复正文。", "target_reply_content": "这里显示被回复的原文。",
                ],
              ]
            ],
          "cursor": ["is_end": true],
        ]
      } else if path.hasSuffix("fetch_session_msgs") {
        data = [
          "messages": [
            [
              "msg_key": "1", "msg_seqno": "1", "sender_uid": 11, "msg_type": 1,
              "timestamp": 1_790_000_000, "content": "{\"content\":\"本地会话内容\"}",
            ],
            [
              "msg_key": "2", "msg_seqno": "2", "sender_uid": 11, "msg_type": 2,
              "timestamp": 1_790_000_001, "content": "{\"url\":\"fixture:gallery\"}",
            ],
          ], "has_more": 0,
        ]
        if ProcessInfo.processInfo.arguments.contains("--qa-message-video") {
          var messages = data["messages"] as? [[String: Any]] ?? []
          messages.append([
            "msg_key": "3", "msg_seqno": "3", "sender_uid": 11, "msg_type": 7,
            "timestamp": 1_790_000_002,
            "content": "{\"source\":5,\"bvid\":\"BV1xx411c7mD\",\"title\":\"消息中的视频\"}",
          ])
          data["messages"] = messages
        }
      } else if path == "/x/polymer/web-dynamic/v1/feed/all" {
        data = ["items": [], "has_more": false]
      } else if path == "/x/v3/fav/folder/created/list-all" {
        data = [
          "list": populated
            ? [
              ["id": 1, "title": "公开收藏夹", "media_count": 6, "attr": 2],
              ["id": 2, "title": "私密收藏夹", "media_count": 6, "attr": 3],
            ] : []
        ]
      } else if path == "/x/v3/fav/resource/list" {
        data = ["medias": videos]
      } else if path == "/x/web-interface/wbi/search/type" {
        let keyword = query.first { $0.name == "keyword" }?.value ?? ""
        if keyword == "失败" {
          client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
          return
        }
        data = [
          "result": Self.empty
            ? [] : [["mid": 11, "uname": "搜索用户 " + keyword, "usign": "本地用户搜索结果", "fans": 42]]
        ]
      } else if path == "/x/web-interface/nav" {
        if Self.sessionRestorationEnabled {
          if ProcessInfo.processInfo.arguments.contains("--qa-session-offline") {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
          }
          if ProcessInfo.processInfo.arguments.contains("--qa-session-expired")
            || !(request.value(forHTTPHeaderField: "Cookie") ?? "").contains("SESSDATA=fixture") {
            code = -101
          }
        }
        data = ["mid": 1, "uname": "本地测试", "isLogin": true, "money": 10.0 - Double(Self.coins)]
      }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(
        self,
        didLoad: (try? JSONSerialization.data(withJSONObject: ["code": code, "message": message, "data": data])) ?? Data())
      client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
  }
#endif
