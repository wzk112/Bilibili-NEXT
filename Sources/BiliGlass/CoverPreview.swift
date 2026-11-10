import AVKit
import BiliModels
import BiliNetworking
import BiliPlayback
import SwiftUI

@MainActor final class CoverPreviewSource {
  let url: URL
  let cid: Int
  private var onStop: (() -> Void)?
  init(url: URL, cid: Int, stop: @escaping () -> Void) { self.url = url; self.cid = cid; onStop = stop }
  func stop() { let action = onStop; onStop = nil; action?() }
  isolated deinit { onStop?() }
}

/// One silent, disposable session for all visible video covers. It never uses
/// the main Playback object, progress callbacks, disk preload or quality prefs.
@MainActor @Observable final class CoverPreview {
  let player = AVPlayer()
  private(set) var hoveredID: String?
  private(set) var activeID: String?
  private(set) var identity = UUID()
  private(set) var ready = false
  private(set) var position = 0.0
  private(set) var comments: [Danmaku] = []
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var commentTask: Task<Void, Never>?
  @ObservationIgnored private var source: CoverPreviewSource?
  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var endObserver: NSObjectProtocol?
  @ObservationIgnored private var statusObservation: NSKeyValueObservation?
  private var frameReady = false
  private var seeking = false
  private let delay: Duration
  private let prepare: (Video) async throws -> CoverPreviewSource
  private let loadComments: (Int) async throws -> [Danmaku]

  init(delay: Duration = .milliseconds(650),
       prepare: @escaping (Video) async throws -> CoverPreviewSource,
       loadComments: @escaping (Int) async throws -> [Danmaku] = { _ in [] }) {
    self.delay = delay; self.prepare = prepare; self.loadComments = loadComments
    player.isMuted = true; player.volume = 0
    player.preventsDisplaySleepDuringVideoPlayback = false
    player.automaticallyWaitsToMinimizeStalling = false
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self, self.activeID != nil, time.seconds.isFinite else { return }
        self.position = max(0, time.seconds)
        if self.frameReady && time.seconds > 0.05 { self.ready = true }
        if time.seconds >= 15 { self.loop() }
      }
    }
    endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
      object: nil, queue: .main) { [weak self] note in
        MainActor.assumeIsolated {
          guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
          self.loop()
        }
      }
  }

  convenience init(api: API) {
    self.init(prepare: { video in
      let detail = try await api.detail(video.bvid)
      guard let page = detail.pages.first else { throw BiliError(text: "没有可预览的分集") }
      let streams = try await api.streams(bvid: video.bvid, cid: page.id, quality: 32)
      let quality = streams.videos.filter { $0.id <= 32 }.map(\.id).max() ?? streams.videos.map(\.id).min()
      let choices = streams.videos.filter { $0.id == quality }
      guard let representation = choices.first(where: { $0.codecs.hasPrefix("avc1") })
        ?? choices.min(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }) else { throw BiliError(text: "暂无预览") }
      let cdn = CDNTransport(source: BiliMediaTransport(), usesSystemProxy: { BiliNetworkPolicy.usesSystemProxy(for: $0) })
      async let selectedVideo = cdn.select(representation, headers: API.mediaHeaders)
      async let selectedAudio = cdn.select(streams.audio, headers: API.mediaHeaders)
      let (route, audio) = try await (selectedVideo, selectedAudio)
      let video = try await VideoSignalling.inspect(route.representation, client: HTTPRangeClient(streamer: cdn)).0
      let asset = try await DASHToHLSBridge(mediaStreamer: cdn).prepare(video: video,
        audio: audio.representation, headers: API.mediaHeaders)
      return CoverPreviewSource(url: asset.url, cid: page.id, stop: { asset.stop() })
    }, loadComments: { cid in
      let data = try await api.binary("/x/v2/dm/web/seg.so", ["type": "1", "oid": "\(cid)", "segment_index": "1"])
      return try await Task.detached(priority: .utility) { try ProtoReader.decode(data) }.value
    })
  }

  func hover(_ video: Video) {
    guard hoveredID != video.bvid else { return }
    stop()
    hoveredID = video.bvid
    let token = identity
    task = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: delay)
        let prepared = try await withDeadline(seconds: 12) { try await self.prepare(video) }
        guard !Task.isCancelled, token == identity else { prepared.stop(); return }
        source = prepared; activeID = video.bvid
        let item = AVPlayerItem(url: prepared.url)
        item.preferredForwardBufferDuration = 2
        item.preferredPeakBitRate = 1_500_000
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
          Task { @MainActor in
            guard let self, let item, token == self.identity, self.player.currentItem === item else { return }
            if item.status == .readyToPlay { self.player.playImmediately(atRate: 1) }
            else if item.status == .failed { self.stop() }
          }
        }
        if UserDefaults.standard.object(forKey: "danmakuEnabled") as? Bool ?? true {
          commentTask = Task { [weak self] in
            guard let self, let rows = try? await loadComments(prepared.cid),
              token == identity, !Task.isCancelled else { return }
            comments = Self.sampleComments(rows, options: .read())
          }
        }
        for _ in 0..<80 {
          try await Task.sleep(for: .milliseconds(100))
          guard token == identity else { return }
          if ready { return }
          if item.status == .failed { break }
        }
        if token == identity { stop() }
      } catch {
        if token == identity { stop() }
      }
    }
  }

  func displayed(_ token: UUID) {
    guard token == identity, activeID != nil else { return }
    frameReady = true
    if position > 0.05 { ready = true }
  }

  func stop(videoID: String? = nil) {
    if let videoID, videoID != hoveredID { return }
    identity = UUID(); hoveredID = nil; activeID = nil; ready = false; frameReady = false
    task?.cancel(); task = nil; commentTask?.cancel(); commentTask = nil
    statusObservation = nil; player.pause(); player.replaceCurrentItem(with: nil)
    source?.stop(); source = nil
    comments = []; position = 0; seeking = false
  }

  private func loop() {
    guard activeID != nil, !seeking else { return }
    seeking = true
    let token = identity
    player.seek(to: .zero) { [weak self] completed in
      Task { @MainActor in
        guard let self, token == self.identity else { return }
        self.seeking = false
        if completed { self.player.playImmediately(atRate: 1) }
      }
    }
  }

  static func sampleComments(_ rows: [Danmaku], options: DanmakuDisplayOptions) -> [Danmaku] {
    var laneTimes = [-Double.infinity, -Double.infinity]
    var result: [Danmaku] = []
    for row in rows.sorted(by: { $0.time < $1.time }) where row.mode == 1 && row.time >= 0 && row.time < 15 && options.accepts(row) {
      guard let lane = laneTimes.indices.min(by: { laneTimes[$0] < laneTimes[$1] }), row.time - laneTimes[lane] >= 5 else { continue }
      laneTimes[lane] = row.time; result.append(row)
      if result.count == 6 { break }
    }
    return result
  }

  isolated deinit {
    task?.cancel(); commentTask?.cancel(); player.pause()
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    source?.stop()
  }
}

private struct CoverPreviewKey: EnvironmentKey {
  static let defaultValue: CoverPreview? = nil
}
extension EnvironmentValues {
  var coverPreview: CoverPreview? {
    get { self[CoverPreviewKey.self] }
    set { self[CoverPreviewKey.self] = newValue }
  }
}

struct CoverPreviewOverlay: View {
  let preview: CoverPreview
  let token: UUID
  var body: some View {
    ZStack {
      CoverPreviewLayer(player: preview.player) { preview.displayed(token) }
      Canvas { context, size in
        for (index, item) in preview.comments.enumerated() {
          let elapsed = preview.position - item.time
          guard elapsed >= 0 && elapsed <= 5 else { continue }
          let color = Color(red: Double((item.color >> 16) & 255) / 255,
            green: Double((item.color >> 8) & 255) / 255, blue: Double(item.color & 255) / 255)
          let text = context.resolve(Text(String(item.text.prefix(40))).font(.system(size: 12, weight: .semibold)).foregroundStyle(color))
          let width = text.measure(in: CGSize(width: 600, height: 18)).width
          let x = size.width - (size.width + width) * elapsed / 5
          var rowContext = context
          rowContext.addFilter(.shadow(color: .black.opacity(0.9), radius: 1))
          rowContext.draw(text, at: CGPoint(x: x, y: 5 + CGFloat(index % 2) * 18), anchor: .topLeading)
        }
      }.opacity(0.9)
    }.opacity(preview.ready ? 1 : 0).allowsHitTesting(false).accessibilityHidden(true)
  }
}

private struct CoverPreviewLayer: NSViewRepresentable {
  let player: AVPlayer
  let ready: () -> Void
  func makeNSView(context: Context) -> LayerView { LayerView(player: player, ready: ready) }
  func updateNSView(_ view: LayerView, context: Context) { view.ready = ready }
  final class LayerView: NSView {
    let videoLayer = AVPlayerLayer()
    var ready: () -> Void
    private var observation: NSKeyValueObservation?
    init(player: AVPlayer, ready: @escaping () -> Void) {
      self.ready = ready
      super.init(frame: .zero)
      wantsLayer = true; videoLayer.player = player; videoLayer.videoGravity = .resizeAspectFill
      layer?.addSublayer(videoLayer)
      observation = videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
        guard layer.isReadyForDisplay else { return }
        Task { @MainActor [weak self] in self?.ready() }
      }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); videoLayer.frame = bounds }
    required init?(coder: NSCoder) { fatalError() }
  }
}
