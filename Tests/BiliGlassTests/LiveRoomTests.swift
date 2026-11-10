import Foundation
import Synchronization
import Testing
import zlib
@testable import BiliGlass

private final class LiveSendProtocol: URLProtocol, @unchecked Sendable {
  static let requests = Mutex<[URLRequest]>([])
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.requests.withLock { $0.append(request) }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    let data: [String: Any]
    if request.url?.path == "/room/v1/Room/get_info" { data = ["room_id": 6, "uid": 42, "title": "直播标题", "area_name": "游戏"] }
    else if request.url?.path == "/live_user/v1/Master/info" { data = ["info": ["uname": "测试主播", "face": "https://i0.hdslb.com/avatar.jpg"]] }
    else { data = [:] }
    client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["code": 0, "data": data]))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct LiveRoomTests {
  @Test func websocketFramesDecodeCombinedAndCompressedMessages() throws {
    let data = try JSONSerialization.data(withJSONObject: ["cmd": "DANMU_MSG:4:0:2:2:2:0", "info": [[0, 1, 25, 16777215], "测试弹幕", [123, "测试用户"]]])
    let original = LiveChatPacket.encode(operation: 5, body: data)
    var compressed = [UInt8](repeating: 0, count: Int(compressBound(uLong(original.count))))
    var size = uLongf(compressed.count)
    let status = original.withUnsafeBytes { source in compress2(&compressed, &size, source.bindMemory(to: UInt8.self).baseAddress, uLong(original.count), Z_DEFAULT_COMPRESSION) }
    #expect(status == Z_OK)
    var envelope = LiveChatPacket.encode(operation: 5, body: Data(compressed.prefix(Int(size))))
    envelope[6] = 0; envelope[7] = 2
    let heartbeat = LiveChatPacket.encode(operation: 3, body: Data([0, 0, 0, 42]))
    let packets = try LiveChatPacket.decode(envelope + heartbeat)
    #expect(packets.map(\.operation) == [5, 3])
    let message = try #require(LiveChatPacket.message(packets[0].body))
    #expect(message.name == "测试用户" && message.text == "测试弹幕")
    #expect(LiveChatPacket.message(Data("{}".utf8)) == nil)
  }

  @Test func malformedWebsocketFramesFailWithoutReadingOutOfBounds() {
    let packet = LiveChatPacket.encode(operation: 5, body: Data("{}".utf8))
    for length in [1, 7, 15, 17] {
      #expect(throws: (any Error).self) { try LiveChatPacket.decode(Data(packet.prefix(length))) }
    }
    var badHeader = packet; badHeader[4] = 0; badHeader[5] = 0
    #expect(throws: (any Error).self) { try LiveChatPacket.decode(badHeader) }
    var badCompression = packet; badCompression[6] = 0; badCompression[7] = 2
    #expect(throws: (any Error).self) { try LiveChatPacket.decode(badCompression) }
  }

  @Test func fMP4RoutesArePreferredAndBackupsRemainAvailable() throws {
    func format(_ name: String, _ host: String) -> [String: Any] {
      ["format_name": name, "codec": [["codec_name": "avc", "base_url": "/live/index.m3u8",
        "current_qn": 250, "accept_qn": [250, 80, 250], "url_info": [["host": host, "extra": "?fixture"]]]]]
    }
    let data: [String: Any] = ["live_status": 1, "playurl_info": ["playurl": ["stream": [["protocol_name": "http_hls",
      "format": [format("ts", "https://ts.bilivideo.com"), format("fmp4", "https://fmp4.bilivideo.com")]]]]]]
    let info = try LivePlayInfo.parse(data)
    #expect(info.urls.map(\.host) == ["fmp4.bilivideo.com", "ts.bilivideo.com"])
    #expect(info.quality == 250 && info.qualities.map(\.id) == [250, 80])
    #expect(throws: (any Error).self) { try LivePlayInfo.parse(["live_status": 0]) }
  }

  @Test func publicRoomMetadataUsesLiveOriginsAndResolvesTheAnchor() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LiveSendProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: config))
    defer { api.session.invalidateAndCancel() }
    let info = try await api.liveRoomInfo(CatalogItem(id: 6, title: "占位", cover: "", subtitle: "", badge: ""))
    #expect(info.id == 6 && info.uid == 42 && info.name == "测试主播")
    #expect(info.title == "直播标题" && info.area == "游戏")
  }

  @Test func sendingChatRequiresLoginAndUsesOnlyTheLiveHostWithCSRF() async throws {
    LiveSendProtocol.requests.withLock { $0 = [] }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LiveSendProtocol.self]
    let api = API(loadCredentials: false, transport: URLSession(configuration: config))
    defer { api.session.invalidateAndCancel() }
    do { _ = try await api.post("/msg/send", ["msg": "fixture", "roomid": "6"]); Issue.record("Guest send must fail") }
    catch { #expect(LiveSendProtocol.requests.withLock { $0.isEmpty }) }
    api.cookies = ["SESSDATA": "fixture", "bili_jct": "fixture-csrf"]
    _ = try await api.post("/msg/send", ["msg": "fixture", "roomid": "6"])
    let request = try #require(LiveSendProtocol.requests.withLock { $0.first })
    #expect(request.url?.host == "api.live.bilibili.com")
    #expect(request.httpMethod == "POST")
    let body: Data?
    if let data = request.httpBody { body = data }
    else if let stream = request.httpBodyStream {
      stream.open(); defer { stream.close() }
      var bytes = [UInt8](repeating: 0, count: 4096)
      let count = stream.read(&bytes, maxLength: bytes.count)
      body = count > 0 ? Data(bytes.prefix(count)) : nil
    } else { body = nil }
    let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
    #expect(text.contains("csrf=fixture-csrf") && text.contains("csrf_token=fixture-csrf"))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["BILIGLASS_LIVE_ROOM_TEST"] == "1"))
  func actualLivePlaybackAndChat() async throws {
    let api = API(loadCredentials: false)
    let room = CatalogItem(id: 232610, title: "公开直播测试", cover: "", subtitle: "", badge: "")
    let model = LiveRoomModel(api: api, room: room)
    defer { model.stop() }
    await model.start()
    try await Task.sleep(for: .seconds(8))
    print("LIVE ROOM loading=\(model.loading) error=\(model.error ?? "none") chat=\(model.chatStatus) messages=\(model.messages.count)")
    #expect(model.error == nil)
    #expect(model.player.currentTime().seconds > 0.1)
    #expect(model.chatStatus == "弹幕已连接")
    #expect(model.info.uid > 0 && !model.info.name.isEmpty)
  }
}
