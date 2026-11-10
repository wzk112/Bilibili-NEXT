import AVKit
import Foundation
import SwiftUI
import zlib

struct LiveQuality: Identifiable, Equatable {
  let id: Int
  let title: String
}
struct LiveRoomInfo {
  let id: Int
  let title: String
  let uid: Int
  let name: String
  let face: String
  let area: String
  let description: String
  let followed: Bool
  static func parse(_ data: [String: Any], fallback: CatalogItem) -> Self {
    let room = data["room_info"] as? [String: Any] ?? [:]
    let anchor = data["anchor_info"] as? [String: Any] ?? [:]
    let base = anchor["base_info"] as? [String: Any] ?? [:]
    let relation = data["user_info"] as? [String: Any] ?? [:]
    return .init(id: room["room_id"] as? Int ?? fallback.id,
      title: room["title"] as? String ?? fallback.title, uid: room["uid"] as? Int ?? 0,
      name: base["uname"] as? String ?? fallback.subtitle, face: base["face"] as? String ?? "",
      area: room["area_name"] as? String ?? fallback.badge,
      description: cleanTitle(room["description"] as? String ?? ""),
      followed: relation["attention"] as? Int == 1)
  }
}

struct LivePlayInfo {
  let urls: [URL]
  let quality: Int
  let qualities: [LiveQuality]
  static func parse(_ data: [String: Any]) throws -> Self {
    guard data["live_status"] as? Int == 1 else { throw BiliError(text: "主播尚未开播") }
    let play = (data["playurl_info"] as? [String: Any])?["playurl"] as? [String: Any] ?? [:]
    let urls = try API.liveHLSURLs(play)
    let streams = play["stream"] as? [[String: Any]] ?? []
    let codecs = streams.filter { $0["protocol_name"] as? String == "http_hls" }
      .flatMap { $0["format"] as? [[String: Any]] ?? [] }
      .flatMap { $0["codec"] as? [[String: Any]] ?? [] }
      .filter { $0["codec_name"] as? String == "avc" }
    let codec = codecs.first ?? [:]
    let descriptions = play["g_qn_desc"] as? [[String: Any]] ?? []
    let names = Dictionary(descriptions.compactMap { row -> (Int, String)? in
      guard let id = row["qn"] as? Int, let title = row["desc"] as? String else { return nil }
      return (id, title)
    }, uniquingKeysWith: { a, _ in a })
    let ids = codec["accept_qn"] as? [Int] ?? []
    var seen = Set<Int>()
    let qualities = ids.filter { $0 > 0 && seen.insert($0).inserted }.sorted(by: >)
      .map { LiveQuality(id: $0, title: names[$0] ?? [10000: "原画", 400: "蓝光", 250: "超清", 150: "高清", 80: "流畅"][$0] ?? String($0)) }
    return .init(urls: urls, quality: codec["current_qn"] as? Int ?? qualities.first?.id ?? 10000, qualities: qualities)
  }
}

struct LiveChatMessage: Identifiable, Sendable {
  let id = UUID()
  let name: String
  let text: String
  let color: Int
  let sequence: Int
  let receivedAt = Date()
}

/// The websocket uses Bilibili's 16-byte packet header and zlib protocol v2.
enum LiveChatPacket {
  struct Packet: Sendable { let operation: UInt32; let body: Data }
  static func encode(operation: UInt32, body: Data) -> Data {
    var result = Data()
    func append<T: FixedWidthInteger>(_ value: T) { var big = value.bigEndian; withUnsafeBytes(of: &big) { result.append(contentsOf: $0) } }
    append(UInt32(body.count + 16)); append(UInt16(16)); append(UInt16(1)); append(operation); append(UInt32(1))
    result.append(body)
    return result
  }
  static func decode(_ data: Data, depth: Int = 0) throws -> [Packet] {
    guard depth < 5, data.count <= 8 * 1024 * 1024 else { throw BiliError(text: "直播弹幕数据过大") }
    let bytes = [UInt8](data)
    func number(_ offset: Int, _ count: Int) -> UInt32 { bytes[offset..<offset + count].reduce(0) { ($0 << 8) | UInt32($1) } }
    var cursor = 0, packets: [Packet] = []
    while cursor < bytes.count {
      guard cursor + 16 <= bytes.count else { throw BiliError(text: "直播弹幕数据不完整") }
      let length = Int(number(cursor, 4)), header = Int(number(cursor + 4, 2))
      let version = number(cursor + 6, 2), operation = number(cursor + 8, 4)
      guard header >= 16, length >= header, length <= bytes.count - cursor else { throw BiliError(text: "直播弹幕数据无效") }
      let body = Data(bytes[cursor + header..<cursor + length])
      if version == 2 {
        var capacity = max(65536, min(8 * 1024 * 1024, body.count * 8))
        var output: [UInt8] = [], size: uLongf = 0, status: Int32 = Z_BUF_ERROR
        repeat {
          output = [UInt8](repeating: 0, count: capacity)
          size = uLongf(capacity)
          status = body.withUnsafeBytes { source in
            uncompress(&output, &size, source.bindMemory(to: UInt8.self).baseAddress, uLong(body.count))
          }
          if status == Z_BUF_ERROR && capacity < 8 * 1024 * 1024 { capacity = min(capacity * 2, 8 * 1024 * 1024) }
          else { break }
        } while true
        guard status == Z_OK else { throw BiliError(text: "直播弹幕解压失败") }
        packets += try decode(Data(output.prefix(Int(size))), depth: depth + 1)
      } else if version == 0 || version == 1 {
        packets.append(.init(operation: operation, body: body))
      } else { throw BiliError(text: "直播弹幕协议暂不支持，请在官网观看") }
      cursor += length
    }
    return packets
  }
  static func message(_ body: Data) -> LiveChatMessage? {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      (root["cmd"] as? String ?? "").hasPrefix("DANMU_MSG"),
      let info = root["info"] as? [Any], info.count >= 3,
      let text = info[1] as? String, let user = info[2] as? [Any], user.count >= 2,
      let name = user[1] as? String else { return nil }
    let options = info[0] as? [Any] ?? []
    return .init(name: name, text: String(text.prefix(500)), color: options.count > 3 ? options[3] as? Int ?? 0xffffff : 0xffffff, sequence: 0)
  }
}

extension API {
  func searchLive(_ query: String, page: Int) async throws -> [CatalogItem] {
    let data = try await request("/x/web-interface/wbi/search/type", ["search_type": "live_room", "keyword": query,
      "page": String(page), "page_size": "24"], signed: true)
    let result = data["result"] as? [String: Any] ?? [:]
    let rows = data["result"] as? [[String: Any]] ?? result["live_room"] as? [[String: Any]] ?? []
    return rows.compactMap { CatalogItem.parse($0, live: true) }
  }
  func livePlayInfo(room: Int, quality: Int) async throws -> LivePlayInfo {
    try LivePlayInfo.parse(await request("/xlive/web-room/v2/index/getRoomPlayInfo", ["room_id": String(room),
      "protocol": "0,1", "format": "0,1,2", "codec": "0", "qn": String(quality), "platform": "web", "ptype": "8"]))
  }
  func liveRoomInfo(_ item: CatalogItem) async throws -> LiveRoomInfo {
    let room = try await request("/room/v1/Room/get_info", ["room_id": String(item.id)])
    let uid = room["uid"] as? Int ?? 0
    let anchor = (try? await request("/live_user/v1/Master/info", ["uid": String(uid)])) ?? [:]
    let base = anchor["info"] as? [String: Any] ?? [:]
    var followed = false
    if signedIn, let relation = try? await request("/x/relation", ["fid": String(uid)]) {
      followed = [2, 6].contains(relation["attribute"] as? Int ?? 0)
    }
    return LiveRoomInfo.parse(["room_info": room, "anchor_info": ["base_info": base],
      "user_info": ["attention": followed ? 1 : 0]], fallback: item)
  }
}

@MainActor @Observable final class LiveRoomModel: Identifiable {
  let id = UUID()
  let player = AVPlayer()
  let api: API
  let room: CatalogItem
  var started = false
  #if os(iOS)
  var fullscreen = false
  var orientation = MobilePlayerOrientation()
  #endif
  var info: LiveRoomInfo
  var qualities: [LiveQuality] = []
  var quality = 10000
  var loading = true
  var error: String?
  var actionMessage: String?
  var messages: [LiveChatMessage] = []
  var chatStatus = "正在连接弹幕"
  var popularity = 0
  var draft = ""
  var sending = false
  var followed = false
  var following = false
  var isPlaying = false
  var volume: Double = 1 { didSet { player.volume = Float(volume) } }
  var danmakuEnabled = true
  var chatAutoScroll = true
  private var messageSequence = 0
  private var generation = UUID()
  private var chatGeneration = UUID()
  private var socket: URLSessionWebSocketTask?
  private var receive: Task<Void, Never>?
  private var heartbeat: Task<Void, Never>?
  private var status: NSKeyValueObservation?
  @ObservationIgnored private var controlStatus: NSKeyValueObservation?
  #if os(macOS)
  private let activity = PlaybackScreenActivity()
  #endif
  init(api: API, room: CatalogItem) {
    self.api = api; self.room = room
    info = LiveRoomInfo.parse([:], fallback: room)
    player.preventsDisplaySleepDuringVideoPlayback = true
    controlStatus = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.isPlaying = self.player.timeControlStatus != .paused
        #if os(macOS)
        self.activity.setPlaying(self.isPlaying && self.error == nil)
        #endif
      }
    }
  }
  func start() async {
    await loadMetadata()
    guard !Task.isCancelled else { return }
    async let playback: () = loadPlayback(10000)
    async let chat: () = connectChat()
    _ = await (playback, chat)
  }
  private func loadMetadata() async {
    do {
      let result = try await api.liveRoomInfo(room)
      try Task.checkCancellation()
      info = result; followed = result.followed
    } catch { /* Playback and chat can still work without optional room metadata. */ }
  }
  func loadPlayback(_ selected: Int) async {
    generation = UUID()
    let token = generation
    let playing = player.currentItem == nil || player.rate != 0
    loading = true; error = nil
    do {
      let play = try await api.livePlayInfo(room: info.id, quality: selected)
      try Task.checkCancellation()
      guard generation == token else { return }
      quality = play.quality; qualities = play.qualities
      for url in play.urls.prefix(3) {
        let headers = API.mediaHeaders.merging(["Referer": "https://live.bilibili.com/\(info.id)"]) { _, new in new }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers]))
        status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
          Task { @MainActor [weak self] in
            guard let self, self.generation == token, self.player.currentItem === item else { return }
            if item.status == .failed && !self.loading {
              let code = item.error as NSError?
              self.error = "直播线路暂时不可用，请重试或切换画质" + (code.map { "（\($0.domain) \($0.code)）" } ?? "")
              #if os(macOS)
              self.activity.setPlaying(false)
              #endif
            }
          }
        }
        player.replaceCurrentItem(with: item)
        if playing { player.play() }
        let began = ContinuousClock.now
        while generation == token {
          try Task.checkCancellation()
          if item.status == .failed { break }
          if item.status == .readyToPlay && (!playing || player.currentTime().seconds > 0.1) {
            loading = false; return
          }
          if began.duration(to: .now) > .seconds(8) { break }
          try await Task.sleep(for: .milliseconds(150))
        }
        guard generation == token else { return }
      }
      loading = false; player.pause()
      error = "直播线路暂时不可用，可切换画质、重试或打开网页直播间"
    } catch {
      guard generation == token, !Task.isCancelled else { return }
      self.error = error.localizedDescription; loading = false
    }
  }
  func connectChat() async {
    disconnectChat()
    let token = chatGeneration
    chatStatus = "正在连接弹幕"
    do {
      let socket = try await openChatSocket(token: token)
      guard token == chatGeneration, !Task.isCancelled else { socket.cancel(with: .goingAway, reason: nil); return }
      self.socket = socket
      chatStatus = "弹幕已连接"
      receive = Task { [weak self] in
        do {
          while !Task.isCancelled {
            let incoming = try await socket.receive()
            let bytes: Data
            switch incoming { case .data(let value): bytes = value; case .string(let text): bytes = Data(text.utf8); @unknown default: continue }
            let packets = try LiveChatPacket.decode(bytes)
            guard let self, self.chatGeneration == token else { return }
            var next: [LiveChatMessage] = []
            for packet in packets {
              if packet.operation == 8 {
                let result = try JSONSerialization.jsonObject(with: packet.body) as? [String: Any]
                guard result?["code"] as? Int == 0 else { throw BiliError(text: "弹幕连接需要重新登录或官网验证") }
                self.chatStatus = "弹幕已连接"
              } else if packet.operation == 3, packet.body.count >= 4 {
                self.popularity = packet.body.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
              } else if packet.operation == 5, let message = LiveChatPacket.message(packet.body) { next.append(message) }
            }
            if !next.isEmpty {
              let numbered = next.map { message -> LiveChatMessage in
                defer { self.messageSequence += 1 }
                return .init(name: message.name, text: message.text, color: message.color, sequence: self.messageSequence)
              }
              self.messages = Array((self.messages + numbered).suffix(200))
            }
          }
        } catch {
          guard let self, self.chatGeneration == token, !Task.isCancelled else { return }
          self.chatStatus = "弹幕连接中断，可重连或在官网查看"
          self.heartbeat?.cancel()
        }
      }
      heartbeat = Task {
        do {
          while !Task.isCancelled {
            try await socket.send(.data(LiveChatPacket.encode(operation: 2, body: Data("[object Object]".utf8))))
            try await Task.sleep(for: .seconds(25))
          }
        } catch { socket.cancel(with: .goingAway, reason: nil) }
      }
    } catch {
      guard token == chatGeneration, !Task.isCancelled else { return }
      chatStatus = "弹幕暂时不可用，可重连或在官网查看"
    }
  }
  private func openChatSocket(token generation: UUID) async throws -> URLSessionWebSocketTask {
    var buvid = api.cookies["buvid3"] ?? ""
    if buvid.isEmpty, let fingerprint = try? await api.request("/x/frontend/finger/spi") {
      buvid = fingerprint["b_3"] as? String ?? ""
      if !buvid.isEmpty { api.cookies["buvid3"] = buvid }
    }
    let data = try await api.request("/xlive/web-room/v1/index/getDanmuInfo",
      ["id": String(info.id), "type": "0", "web_location": "444.8"], signed: true)
    guard let key = data["token"] as? String, !key.isEmpty,
      let hosts = data["host_list"] as? [[String: Any]] else { throw BiliError(text: "弹幕服务器暂时不可用") }
    let auth: [String: Any] = ["uid": Int(api.cookies["DedeUserID"] ?? "") ?? 0, "roomid": info.id,
      "protover": 2, "platform": "web", "type": 2, "key": key, "buvid": buvid]
    let body = try JSONSerialization.data(withJSONObject: auth)
    for server in hosts.prefix(3) {
      try Task.checkCancellation()
      guard generation == chatGeneration else { throw CancellationError() }
      guard let host = server["host"] as? String, host.hasSuffix(".chat.bilibili.com") else { continue }
      let port = server["wss_port"] as? Int ?? 443
      guard (1...65535).contains(port), let url = URL(string: "wss://\(host):\(port)/sub") else { continue }
      var request = URLRequest(url: url)
      API.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
      let socket = api.session.webSocketTask(with: request)
      socket.maximumMessageSize = 8 * 1024 * 1024
      self.socket = socket; socket.resume()
      do {
        try await socket.send(.data(LiveChatPacket.encode(operation: 7, body: body)))
        let message = try await withDeadline(seconds: 8) {
          try await withTaskCancellationHandler(operation: { try await socket.receive() },
            onCancel: { socket.cancel(with: .goingAway, reason: nil) })
        }
        let bytes: Data
        switch message { case .data(let data): bytes = data; case .string(let text): bytes = Data(text.utf8); @unknown default: throw BiliError(text: "弹幕响应无效") }
        let packets = try LiveChatPacket.decode(bytes)
        guard let auth = packets.first(where: { $0.operation == 8 }),
          let reply = try JSONSerialization.jsonObject(with: auth.body) as? [String: Any],
          reply["code"] as? Int == 0 else { throw BiliError(text: "弹幕连接需要重新登录或官网验证") }
        return socket
      } catch { socket.cancel(with: .goingAway, reason: nil) }
    }
    throw BiliError(text: "弹幕服务器连接失败")
  }
  func send() async {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sending, !text.isEmpty, text.count <= 100 else { return }
    sending = true; actionMessage = nil
    defer { sending = false }
    do {
      _ = try await api.post("/msg/send", ["roomid": String(info.id), "msg": text, "bubble": "0", "mode": "1",
        "fontsize": "25", "color": "16777215", "rnd": String(Int(Date().timeIntervalSince1970))])
      if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
      actionMessage = "弹幕已发送"
    } catch { actionMessage = error.localizedDescription }
  }
  func toggleFollow() async {
    guard info.uid > 0, !following else { return }
    following = true; actionMessage = nil
    defer { following = false }
    do {
      _ = try await api.post("/x/relation/modify", ["fid": String(info.uid), "act": followed ? "2" : "1", "re_src": "11"])
      followed.toggle()
    } catch { actionMessage = error.localizedDescription }
  }
  private func disconnectChat() {
    chatGeneration = UUID(); receive?.cancel(); heartbeat?.cancel()
    receive = nil; heartbeat = nil
    socket?.cancel(with: .goingAway, reason: nil); socket = nil
  }
  func stop() {
    generation = UUID(); disconnectChat(); status = nil
    player.pause(); player.replaceCurrentItem(with: nil)
    #if os(iOS)
    orientation.restore(); fullscreen = false
    #endif
    #if os(macOS)
    activity.setPlaying(false)
    #endif
  }
}

private struct LiveDanmakuOverlay: View {
  let messages: [LiveChatMessage]
  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
      Canvas { context, size in
        context.addFilter(.shadow(color: .black.opacity(0.9), radius: 1))
        for message in messages.suffix(20) {
          let age = timeline.date.timeIntervalSince(message.receivedAt)
          guard age >= 0, age < 8 else { continue }
          let text = context.resolve(Text(message.text).font(.system(size: 20, weight: .semibold)).foregroundColor(.white))
          let width = text.measure(in: CGSize(width: 1200, height: 30)).width
          let x = size.width - (size.width + width) * age / 8
          let y = 20 + CGFloat(message.sequence % 6) * 30
          context.draw(text, at: CGPoint(x: x, y: y), anchor: .topLeading)
        }
      }
    }.clipped()
  }
}

struct CatalogLivePlayer: View {
  let store: Store
  let room: CatalogItem
  @Environment(\.dismiss) private var dismiss
  @State private var model: LiveRoomModel
  @State private var showWebsite = false
  #if os(iOS)
  private var fullscreen: Bool { model.fullscreen }
  private var orientation: MobilePlayerOrientation { model.orientation }
  #endif
  init(store: Store, room: CatalogItem) {
    self.store = store; self.room = room
    _model = State(initialValue: LiveRoomModel(api: store.api, room: room))
  }
  init(store: Store, model: LiveRoomModel) {
    self.store = store; room = model.room
    _model = State(initialValue: model)
  }
  var body: some View {
    ZStack {
      #if os(iOS)
      if fullscreen { fullscreenPlayer }
      else { roomContent }
      #else
      roomContent
      #endif
    }
      .task {
        guard !model.started else { return }
        model.started = true
        #if DEBUG && os(iOS)
        if let file = Self.fixture {
          model.player.replaceCurrentItem(with: AVPlayerItem(url: file))
          model.player.play(); model.loading = false
          model.chatStatus = "本地直播界面测试"
          return
        }
        #endif
        await model.start()
      }
      .onDisappear {
        #if os(macOS)
        model.stop()
        #endif
      }
      .sheet(isPresented: $showWebsite) { website }
      #if os(iOS)
      .onChange(of: fullscreen) { if !fullscreen { orientation.restore() } }
      .background(MobilePlayerWindowReader(orientation: orientation))
      #endif
  }
  private var roomContent: some View {
    GeometryReader { geometry in
      let wide = geometry.size.width >= 900
      VStack(alignment: .leading, spacing: AppMetrics.sectionSpacing) {
        header(compact: geometry.size.width < 650)
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
        layout {
          VStack(spacing: 12) { inlineVideo; controls }.frame(maxWidth: .infinity)
          chat.frame(width: wide ? 300 : nil, height: wide ? nil : max(220, geometry.size.height * 0.36))
        }
      }.padding(AppMetrics.pageInset)
    }.liveRoomPresentationSize()
  }
  private func header(compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Thumbnail(url: model.info.face, mode: .fill, placeholder: "person.crop.circle").frame(width: 40, height: 40).clipShape(.circle)
        VStack(alignment: .leading, spacing: 4) {
          Text(model.info.title).font(.headline).lineLimit(1)
          Text([model.info.name, model.info.area, "直播间 \(model.info.id)"].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 8)
        if !compact { roomActions }
        Button {
          #if os(iOS)
          model.stop(); store.liveRoom = nil
          #else
          dismiss()
          #endif
        } label: {
          Image(systemName: "xmark").frame(width: 20, height: 20)
        }.moduleControl().accessibilityLabel("关闭直播间").keyboardShortcut(.cancelAction)
      }
      if compact { HStack { roomActions; Spacer() } }
    }.buttonStyle(.appGlassButton).controlSize(.regular)
  }
  private var roomActions: some View {
    Group {
      Button { Task { await model.toggleFollow() } } label: {
        Label(model.followed ? "已关注" : "关注", systemImage: model.followed ? "checkmark" : "plus")
      }.disabled(store.account == nil || model.info.uid == 0 || model.following).moduleControl()
      Button { showWebsite = true } label: { Label("网页直播间", systemImage: "globe") }.moduleControl()
    }
  }
  @ViewBuilder private var inlineVideo: some View {
    video.aspectRatio(16 / 9, contentMode: .fit).clipShape(.rect(cornerRadius: AppMetrics.cardRadius))
  }
  private var video: some View {
    Group {
      #if os(iOS)
      MobileLiveVideo(player: model.player)
      #else
      VideoPlayer(player: model.player)
      #endif
    }
      .overlay(alignment: .topTrailing) {
        if model.danmakuEnabled {
          LiveDanmakuOverlay(messages: model.messages).allowsHitTesting(false)
        }
      }
      .overlay {
        if model.loading { ProgressView("正在加载直播").padding(16).background(.regularMaterial, in: .rect(cornerRadius: 12)) }
        if let error = model.error {
          VStack(spacing: 12) {
            Text(error).multilineTextAlignment(.center)
            Button("重试") { Task { await model.loadPlayback(model.quality) } }
          }.padding(20).background(.regularMaterial, in: .rect(cornerRadius: 12)).padding(20)
        }
      }.background(.black)
  }
  private var controls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) { playbackButton; quality; Toggle("画面弹幕", isOn: $model.danmakuEnabled); Spacer(); volume; fullscreenButton }
      VStack(spacing: 12) {
        HStack { quality; Spacer(); Toggle("画面弹幕", isOn: $model.danmakuEnabled) }
        HStack { playbackButton; volume; Spacer(); fullscreenButton }
      }
    }.controlSize(.regular).font(.callout)
  }
  private var playbackButton: some View {
    Button {
      if model.player.timeControlStatus == .paused { model.player.play() } else { model.player.pause() }
    } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20, height: 20) }
      .buttonStyle(.appGlassButton).moduleControl()
      .accessibilityLabel("播放或暂停直播").accessibilityValue(model.isPlaying ? "正在播放" : "已暂停")
      .accessibilityIdentifier("live-play-pause")
  }
  @ViewBuilder private var fullscreenButton: some View {
    #if os(iOS)
    Button {
      orientation.remember()
      model.fullscreen = true
    } label: { Label("全屏", systemImage: "arrow.up.left.and.arrow.down.right") }
      .buttonStyle(.appGlassButton).moduleControl().fixedSize()
      .accessibilityIdentifier("live-enter-fullscreen")
    #endif
  }
  #if os(iOS)
  private var fullscreenPlayer: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      video.ignoresSafeArea()
      VStack {
        HStack(spacing: 16) {
          Button { model.fullscreen = false } label: {
            Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(.rect)
          }.accessibilityLabel("退出直播全屏").accessibilityIdentifier("live-exit-fullscreen")
          Text(model.info.title).font(.headline).lineLimit(1)
          Spacer(minLength: 12)
          playbackButton
          quality
          Button { model.danmakuEnabled.toggle() } label: {
            Image(systemName: model.danmakuEnabled ? "text.bubble.fill" : "text.bubble")
              .frame(width: 44, height: 44).contentShape(.rect)
          }.accessibilityLabel(model.danmakuEnabled ? "关闭画面弹幕" : "开启画面弹幕")
        }.padding(.horizontal, 16).padding(.vertical, 4)
          .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
        Spacer()
      }.foregroundStyle(.white)
    }.statusBarHidden()
      .background(MobilePlayerWindowReader(orientation: orientation, requestLandscape: true))
      .alert("无法调整屏幕方向", isPresented: Binding(get: { orientation.error != nil }, set: { if !$0 { orientation.error = nil } })) {
        Button("好") { orientation.error = nil }
      } message: { Text(orientation.error ?? "") }
  }
  #if DEBUG
  static var fixture: URL? {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "--qa-live-fixture"), args.indices.contains(index + 1),
      args[index + 1] == (args[index + 1] as NSString).lastPathComponent else { return nil }
    let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("QA").appendingPathComponent(args[index + 1])
    return FileManager.default.fileExists(atPath: file.path) ? file : nil
  }
  #endif
  #endif
  private var quality: some View {
    Menu {
      ForEach(model.qualities) { quality in
        Button { Task { await model.loadPlayback(quality.id) } } label: {
          if model.quality == quality.id { Label(quality.title, systemImage: "checkmark") } else { Text(quality.title) }
        }
      }
    } label: { Label(model.qualities.first(where: { $0.id == model.quality })?.title ?? "画质", systemImage: "slider.horizontal.3") }
      .disabled(model.qualities.isEmpty).buttonStyle(.appGlassButton).moduleControl().fixedSize(horizontal: true, vertical: false)
  }
  private var volume: some View {
    HStack(spacing: 8) {
      Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2")
      Slider(value: $model.volume, in: 0...1).frame(maxWidth: 140).accessibilityLabel("直播音量")
    }
  }
  private var chat: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("实时弹幕").font(.headline)
        Spacer()
        Button("重连") { Task { await model.connectChat() } }.buttonStyle(.appGlassButton)
      }
      Text(model.chatStatus + (model.popularity > 0 ? " · 人气 \(model.popularity.formatted(.number.notation(.compactName)))" : ""))
        .font(.caption).foregroundStyle(.secondary)
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(model.messages) { message in
              (Text(message.name + "：").foregroundColor(.secondary) + Text(message.text))
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading).id(message.id)
            }
          }
        }.onChange(of: model.messages.last?.id) {
          if model.chatAutoScroll, let id = model.messages.last?.id { reader.scrollTo(id, anchor: .bottom) }
        }
      }
      Toggle("自动滚动", isOn: $model.chatAutoScroll).font(.caption).toggleStyle(.switch)
      HStack(spacing: 8) {
        TextField(store.account == nil ? "登录后发送弹幕" : "发送弹幕", text: $model.draft)
          .textFieldStyle(.roundedBorder).onSubmit { Task { await model.send() } }.disabled(store.account == nil)
        Button("发送") { Task { await model.send() } }.buttonStyle(.appGlassProminent)
          .disabled(store.account == nil || model.sending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.draft.count > 100)
      }
      if let message = model.actionMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
    }.padding(16).background(.regularMaterial, in: .rect(cornerRadius: AppMetrics.cardRadius))
  }
  private var website: some View {
    let target = WebTarget(url: URL(string: "https://live.bilibili.com/\(model.info.id)")!, title: "直播间")
    return VStack(spacing: 0) {
      HStack { Text("网页直播间").font(.headline); Spacer(); Button("返回原生直播间") { showWebsite = false } }.padding(12)
      #if os(macOS)
      OfficialWebPanel(target: target, api: store.api)
      #else
      MobileWebPage(store: store, target: target)
      #endif
    }.frame(minWidth: 320, idealWidth: 1180, minHeight: 500, idealHeight: 760)
      .onAppear { model.player.pause() }
  }
}

#if os(iOS)
/// Detaching a presentation must not pause the room's shared player. The room owns
/// playback; AVKit controllers only own their current inline/fullscreen surface.
private struct MobileLiveVideo: UIViewControllerRepresentable {
  let player: AVPlayer
  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.allowsPictureInPicturePlayback = true
    controller.videoGravity = .resizeAspect
    return controller
  }
  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player { controller.player = player }
  }
  static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
    controller.player = nil
  }
}
#endif

private extension View {
  @MainActor @ViewBuilder func liveRoomPresentationSize() -> some View {
    #if os(macOS)
    frame(width: min(1120, (NSScreen.main?.visibleFrame.width ?? 1184) - 64),
      height: min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
    #else
    frame(maxWidth: .infinity, maxHeight: .infinity)
    #endif
  }
}
