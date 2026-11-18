import Foundation
import Synchronization
import Testing
@testable import BiliGlass

private final class ExpansionProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var response: (@Sendable (URLRequest) throws -> Data)?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      let data = try Self.response!(request)
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}
@Suite(.serialized) struct FeatureExpansionTests {
  @MainActor private func api() -> API {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ExpansionProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: config))
    api.cookies = ["SESSDATA": "fixture", "bili_jct": "fixture-csrf", "buvid3": "fixture"]
    return api
  }
  @Test func messageStringSequenceAndSessionTimestampRemainUsable() throws {
    let message = try #require(PrivateMessage.parse([
      "msg_seqno": "9007199254740993", "msg_type": 1, "content": "{}" ]))
    #expect(message.id == "9007199254740993")
    #expect(message.sequence == "9007199254740993")
    let conversation = try #require(Conversation.parse([
      "talker_id": "42", "session_type": 7, "session_ts": "1790000000000000" ]))
    #expect(conversation.system)
    #expect(conversation.date == Date(timeIntervalSince1970: 1790000000))
    #expect(Conversation(mid: 1, kind: 1, name: "", face: "", preview: "", unread: 0,
      timestamp: 0, system: false).date == nil)
  }
  @Test @MainActor func failedReadAcknowledgementPreservesUnreadAndLoadedMessages() async {
    let inbox = InboxModel()
    let conversation = Conversation(mid: 7, kind: 1, name: "fixture", face: "", preview: "",
      unread: 3, timestamp: 0, system: false)
    inbox.conversations = [conversation]
    inbox.select(conversation)
    ExpansionProtocol.response = { request in
      if request.url?.path.hasSuffix("update_ack") == true { throw URLError(.timedOut) }
      return Data(#"{"code":0,"data":{"messages":[{"msg_key":"1","msg_seqno":"5","msg_type":1,"content":"{}"}],"has_more":0}}"#.utf8)
    }
    defer { ExpansionProtocol.response = nil }
    await inbox.loadMessages(api: api())
    #expect(inbox.conversations.first?.unread == 3)
    #expect(inbox.messages.count == 1)
    #expect(inbox.messageError != nil)
    #expect(!inbox.loadingMessages)
  }
  @Test func privateEmotesUseServerMetadataAndKeepUnknownText() {
    let emotes = CommentEmote.privateMessages([
      ["text": "[爱心]", "url": "//i0.hdslb.com/bfs/emote/heart.png", "size": 1],
      ["text": "[bad]", "url": "https://untrusted.example/a.png", "size": 1]])
    let content = CommentTextContent(message: "谢谢[爱心][爱心]🙂[原文]", emotes: emotes)
    #expect(content.parts.count == 4)
    #expect(content.emotes.count == 1)
    #expect(content.message == "谢谢[爱心][爱心]🙂[原文]")
    #expect(emotes["[bad]"] == nil)
  }
  @Test func subtitlesRejectInvalidTimesAndKeepBoundarySemantics() {
    let cues = SubtitleLine.parse([
      ["from": 2.0, "to": 3.0, "content": "second"],
      ["from": 0.0, "to": 2.0, "content": "first"],
      ["from": -1.0, "to": 1.0, "content": "invalid"]])
    #expect(cues.count == 2); #expect(cues.first?.text == "first")
  }
  @Test @MainActor func subtitleSelectionDoesNotCarryAcrossVideos() {
    let model = VideoExtras(); model.lines = [.init(start: 0, end: 2, text: "first"), .init(start: 2, end: 4, text: "second")]
    #expect(model.text(at: 1.99) == "first"); #expect(model.text(at: 2) == "second"); #expect(model.text(at: 4).isEmpty)
    model.reset(); #expect(model.text(at: 1).isEmpty)
  }
  @Test @MainActor func recommendationsLoadOncePerVideoAndRespectVisibility() async throws {
    let requests = Mutex([String]())
    ExpansionProtocol.response = { request in
      let path = request.url?.path ?? ""
      requests.withLock { $0.append(path) }
      if path == "/x/web-interface/archive/related" {
        return Data(#"{"code":0,"data":[{"bvid":"BV1xx411c7mD"},{"bvid":"BV1nWns6xELb"},{"bvid":"BV1nWns6xELb"}]}"#.utf8)
      }
      return Data(#"{"code":0,"data":[{"tag_id":1,"tag_name":"测试标签"}]}"#.utf8)
    }
    defer { ExpansionProtocol.response = nil }
    let detail = Detail(video: try #require(Video.parse(["bvid": "BV1xx411c7mD"])), description: "", pages: [])
    let model = VideoExtras()
    let client = api()
    await model.loadDiscovery(detail: detail, api: client, includeRelated: false)
    #expect(model.related.isEmpty)
    #expect(model.tags.map(\.title) == ["测试标签"])
    #expect(requests.withLock { $0 } == ["/x/tag/archive/tags"])
    await model.loadDiscovery(detail: detail, api: client)
    await model.loadDiscovery(detail: detail, api: client)
    #expect(model.related.map(\.bvid) == ["BV1nWns6xELb"])
    #expect(requests.withLock { $0.filter { $0 == "/x/web-interface/archive/related" }.count } == 1)
    #expect(!model.loadingRecommendations)
  }
  @Test func currentRegionPayloadRetainsCoverAuthorAndVideoIdentity() throws {
    let video = try #require(Video.parse(["bvid": "BV1xx411c7mD", "aid": 42, "cover": "https://i0.hdslb.com/test.jpg", "author": ["mid": 7, "name": "作者"], "duration": 60]))
    #expect(video.author == "作者"); #expect(video.ownerID == 7); #expect(video.aid == 42); #expect(!video.cover.isEmpty)
    let ids = VideoRegion.all.flatMap { [$0.id] + $0.children.map(\.id) }
    #expect(Set(ids).count == ids.count); #expect(VideoRegion.parent(of: 2037).title == "动画")
  }
  @Test func collectionQueueUsesEpisodeCIDAndIgnoresDuplicates() throws {
    let collection = try #require(VideoCollection.parse(["title": "系列", "sections": [["episodes": [
      ["bvid": "BV1xx411c7mD", "cid": 1, "title": "第一集"], ["bvid": "BV1xx411c7mD", "cid": 1, "title": "重复"],
      ["bvid": "BV1xx411c7mD", "cid": 2, "title": "第二集"]]]]]))
    #expect(collection.items.map(\.cid) == [1, 2])
  }
  @Test @MainActor func recallWindowAndOwnershipAreEnforced() throws {
    let message = try #require(PrivateMessage.parse(["msg_key": "1", "msg_type": 1, "sender_uid": 42, "timestamp": 1000, "content": "{\"content\":\"hello\"}"]))
    let inbox = InboxModel()
    #expect(inbox.canRecall(message, accountID: 42, now: Date(timeIntervalSince1970: 1119)))
    #expect(!inbox.canRecall(message, accountID: 7, now: Date(timeIntervalSince1970: 1010)))
    #expect(!inbox.canRecall(message, accountID: 42, now: Date(timeIntervalSince1970: 1121)))
  }
  @Test @MainActor func historyPagesMergePrivateEmotesInsteadOfDroppingEarlierMetadata() async {
    let inbox = InboxModel(); inbox.select(.init(mid: 7, kind: 1, name: "fixture", face: "", preview: "", unread: 0, timestamp: 0, system: false))
    ExpansionProtocol.response = { _ in Data(#"{"code":0,"data":{"messages":[{"msg_key":"1","sender_uid":7,"msg_type":1,"timestamp":1000,"content":"{\"content\":\"[爱心]\"}"}],"e_infos":[{"text":"[爱心]","url":"https://i0.hdslb.com/heart.png","size":1}],"has_more":0}}"#.utf8) }
    defer { ExpansionProtocol.response = nil }
    await inbox.loadMessages(api: api(), markRead: false)
    #expect(inbox.messages.count == 1); #expect(inbox.emotes["[爱心]"] != nil)
    ExpansionProtocol.response = { _ in Data(#"{"code":0,"data":{"messages":[],"e_infos":[],"has_more":0}}"#.utf8) }
    await inbox.loadMessages(api: api(), markRead: false)
    #expect(inbox.emotes["[爱心]"] != nil)
  }
  @Test @MainActor func regionWireRequestUsesCurrentRegionFeed() async throws {
    ExpansionProtocol.response = { request in
      #expect(request.url?.path == "/x/web-interface/region/feed/rcmd")
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      #expect(query.contains { $0.name == "from_region" && $0.value == "1012" })
      #expect(query.contains { $0.name == "request_cnt" && $0.value == "15" })
      return Data(#"{"code":0,"data":{"archives":[{"bvid":"BV1xx411c7mD","cover":"https://i0.hdslb.com/a.jpg","author":{"name":"fixture"}}]}}"#.utf8)
    }
    defer { ExpansionProtocol.response = nil }
    #expect(try await api().regionVideos(1012, page: 2).count == 1)
  }
  @Test @MainActor func conversationPaginationUsesLastRawTimestampIncludingPinnedAndStringRows() async {
    ExpansionProtocol.response = { request in
      if request.url!.path.contains("cards") { return Data(#"{"code":0,"data":{"items":[]}}"#.utf8) }
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      #expect(query.contains { $0.name == "session_type" && $0.value == "1" })
      var cursor: String?
      for item in query where item.name == "end_ts" { cursor = item.value }
      if cursor == nil {
        return Data(#"{"code":0,"data":{"has_more":1,"session_list":[{"talker_id":1,"session_ts":50},{"talker_id":"2","session_type":"1","session_ts":"300"},{"talker_id":3,"session_ts":"200"}]}}"#.utf8)
      }
      #expect(cursor == "200")
      return Data(#"{"code":0,"data":{"has_more":0,"session_list":[{"talker_id":3,"session_ts":200},{"talker_id":4,"session_ts":100}]}}"#.utf8)
    }
    defer { ExpansionProtocol.response = nil }
    let model = InboxModel(), api = api()
    await model.load(api: api); #expect(model.conversations.count == 3); #expect(model.hasMore)
    await model.load(api: api, more: true)
    #expect(model.conversations.map(\.mid) == [1, 2, 3, 4]); #expect(!model.hasMore); #expect(model.error == nil)
  }
  @Test @MainActor func repeatedConversationCursorIsVisibleAndKeepsExistingRows() async {
    ExpansionProtocol.response = { request in
      if request.url!.path.contains("cards") { return Data(#"{"code":0,"data":{"items":[]}}"#.utf8) }
      return Data(#"{"code":0,"data":{"has_more":1,"session_list":[{"talker_id":1,"session_ts":100}]}}"#.utf8)
    }
    defer { ExpansionProtocol.response = nil }
    let model = InboxModel(), api = api()
    await model.load(api: api); await model.load(api: api, more: true)
    #expect(model.conversations.count == 1); #expect(model.error?.contains("重复") == true); #expect(!model.loading)
  }
  @Test func dynamicRepostUsesCurrentSceneAndPreservesUnicodeEmoji() throws {
    let emote = CommentEmote.privateMessages([["text": "[爱心]", "url": "https://i0.hdslb.com/heart.png"]])
    let body = DynamicPayload.request(text: "中文🙂[爱心][原文]", emotes: emote, images: [], uploadID: "42_1000_1234", repostID: "123", aiGenerated: false)
    let request = try #require(body["dyn_req"] as? [String: Any])
    #expect(request["scene"] as? Int == 4)
    #expect((body["web_repost_src"] as? [String: String])?["dyn_id_str"] == "123")
    let nodes = try #require((request["content"] as? [String: Any])?["contents"] as? [[String: Any]])
    #expect(nodes.compactMap { $0["raw_text"] as? String }.joined() == "中文🙂[爱心][原文]")
    #expect(nodes.compactMap { $0["type"] as? Int } == [1, 9, 1])
  }
  @Test @MainActor func dynamicPrecheckFailureNeverSubmitsAndKeepsDraft() async {
    ExpansionProtocol.response = { request in
      #expect(request.httpMethod == "POST"); #expect(request.url?.path == "/x/dynamic/feed/create/submit_check")
      #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "csrf" && $0.value == "fixture-csrf" } == true)
      return Data(#"{"code":-352,"message":"需要验证"}"#.utf8)
    }
    defer { ExpansionProtocol.response = nil }
    let draft = DynamicDraft(); draft.text = "fixture"
    #expect(await draft.publish(api: api(), mid: 42, repostID: nil) == false)
    #expect(draft.text == "fixture"); #expect(draft.error?.contains("验证") == true); #expect(!draft.publishing)
  }
  @Test @MainActor func blacklistCanLoadPastFirstPageAndRetryWithoutDroppingRows() async {
    ExpansionProtocol.response = { request in
      let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
      var page = ""
      for item in query where item.name == "pn" { page = item.value ?? "" }
      #expect(request.url?.path == "/x/relation/blacks")
      let rows = page == "1" ? (1...50).map { ["mid": $0, "uname": "fixture"] as [String: Any] } : [["mid": 51, "uname": "last"]]
      return try JSONSerialization.data(withJSONObject: ["code": 0, "data": ["list": rows, "total": 51]])
    }
    defer { ExpansionProtocol.response = nil }
    let model = BlacklistModel(), api = api()
    await model.load(api: api); #expect(model.rows.count == 50); #expect(model.hasMore)
    ExpansionProtocol.response = { _ in Data(#"{"code":-412,"message":"fixture error"}"#.utf8) }
    await model.load(api: api); #expect(model.rows.count == 50); #expect(model.hasMore); #expect(model.error != nil)
    ExpansionProtocol.response = { request in
      #expect(request.url!.query!.contains("pn=2"))
      return Data(#"{"code":0,"data":{"list":[{"mid":51,"uname":"last"}],"total":51}}"#.utf8)
    }
    await model.load(api: api); #expect(model.rows.count == 51); #expect(!model.hasMore); #expect(model.error == nil)
  }
  @Test func seekPreviewTracksPointerAndStaysInsideBothEdges() {
    #expect(SeekPreviewGeometry.time(pointer: 500, duration: 100, width: 1000) == 50)
    #expect(SeekPreviewGeometry.time(pointer: 8, duration: 100, width: 1000) == 0)
    #expect(SeekPreviewGeometry.time(pointer: 992, duration: 100, width: 1000) == 100)
    #expect(SeekPreviewGeometry.origin(time: 0, duration: 100, width: 1000) == 0)
    #expect(SeekPreviewGeometry.origin(time: 50, duration: 100, width: 1000) == 414)
    #expect(SeekPreviewGeometry.origin(time: 100, duration: 100, width: 1000) == 828)
    #expect(SeekPreviewGeometry.origin(time: .nan, duration: 0, width: 1000) == 0)
  }
  @Test func videoReportsUseLeafReasonsRatherThanUnsubmittableSectionIDs() {
    let reasons = VideoReportReason.parse([["tid": 1, "name": "category", "sub_tag": [
      ["tid": 2, "name": "reason", "type": "normal"], ["tid": 3, "name": "external", "type": "jump"]]]])
    #expect(reasons.map(\.id) == [2])
  }
  @Test @MainActor func commentAndDynamicImagesUseOfficialBusinessAndReturnedDimensions() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX6kAAAAASUVORK5CYII=")!.write(to: url)
    defer { try? FileManager.default.removeItem(at: url); ExpansionProtocol.response = nil }
    ExpansionProtocol.response = { request in
      #expect(request.url?.path == "/x/dynamic/feed/draw/upload_bfs")
      var body = request.httpBody ?? Data()
      if body.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(buffer, count: count) }
      }
      let text = String(decoding: body, as: UTF8.self)
      #expect(text.contains("name=\"biz\"\r\n\r\nnew_dyn"))
      #expect(text.contains("name=\"category\"\r\n\r\ndaily"))
      #expect(text.contains("name=\"csrf\"\r\n\r\nfixture-csrf"))
      return Data(#"{"code":0,"data":{"image_url":"https://i0.hdslb.com/fixture.png","image_width":1,"image_height":1,"img_size":0.05}}"#.utf8)
    }
    let image = try await api().uploadImage(url, business: "new_dyn")
    #expect(image.width == 1); #expect(image.commentPayload["img_size"] as? Double == 0.05)
  }
}

@Suite struct MobileMigrationContentTests {
  @Test func commentPictureURLsUseTheSameHTTPSNormalizationAsTheirThumbnails() {
    #expect(BiliImageURL.parse("http://i0.hdslb.com/bfs/new_dyn/image.jpg")?.absoluteString == "https://i0.hdslb.com/bfs/new_dyn/image.jpg")
    #expect(BiliImageURL.parse("//i1.hdslb.com/picture.png")?.scheme == "https")
    #expect(BiliImageURL.parse("https://i0.hdslb.com.evil.test/picture.png") == nil)
    #expect(BiliImageURL.parse("file:///etc/passwd") == nil)
    #expect(BiliImageURL.parse("https://user:password@i0.hdslb.com/picture.png") == nil)
  }
  @Test func liveAndArticleDynamicsKeepAnAttachmentInsteadOfAnEmptyBody() throws {
    let content = String(decoding: try JSONSerialization.data(withJSONObject: ["live_play_info": ["title":"Live fixture", "room_id":123, "cover":"https://i0.hdslb.com/cover.jpg"]]), as: UTF8.self)
    let live = try #require(DynamicAttachment.parse(major:["live_rcmd":["content":content]]))
    #expect(live.title == "Live fixture")
    #expect(live.url?.absoluteString == "https://live.bilibili.com/123")
    let article = try #require(DynamicAttachment.parse(major:["article":["title":"Article fixture", "covers":["https://i0.hdslb.com/article.jpg"], "jump_url":"//www.bilibili.com/read/cv123"]]))
    #expect(article.kind == "专栏")
    #expect(article.cover == "https://i0.hdslb.com/article.jpg")
    #expect(article.url?.scheme == "https")
  }
  @Test func deletedDynamicPreservesTheServerExplanation() throws {
    let entry = try #require(DynamicEntry.parse(["id_str":"123", "modules":["module_dynamic":["major":["none":["tips":"内容已删除"]]]]]))
    #expect(entry.unavailableText == "内容已删除")
    #expect(entry.attachment == nil)
  }
}
