import AVKit
import SwiftUI

@MainActor @Observable final class LivePlayback {
  let player = AVPlayer()
  private(set) var loading = false
  private(set) var error: String?
  private(set) var quality = 0
  private(set) var qualities: [Int: String] = [:]
  @ObservationIgnored private var relay: LiveHLSRelay?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var watchdog: Task<Void, Never>?
  @ObservationIgnored private var statusObservation: NSKeyValueObservation?
  @ObservationIgnored private var controlObservation: NSKeyValueObservation?
  @ObservationIgnored private let activity = PlaybackScreenActivity()
  private var generation = UUID()
  init() {
    player.preventsDisplaySleepDuringVideoPlayback = true
    controlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.activity.setPlaying(self.player.timeControlStatus == .playing && self.error == nil)
      }
    }
  }
  func open(_ room: LiveRoom, api: API, quality: Int = 10000, playing: Bool = true) {
    stop()
    guard LiveAvailability.enabled else { error = LiveAvailability.message; return }
    loading = true
    guard room.isLive else { loading = false; error = "主播暂未开播"; return }
    let token = generation
    task = Task { [self] in
      do {
        let stream = try await api.liveStream(roomID: room.id, quality: quality)
        try Task.checkCancellation()
        var lastError: Error = BiliError(text: "直播线路暂不可用")
        for url in stream.urls.prefix(4) {
          let relay = LiveHLSRelay()
          do {
            let local = try await relay.start(url: url)
            try Task.checkCancellation()
            guard token == generation else { await relay.stop(); return }
            self.relay = relay; self.quality = stream.quality; qualities = stream.qualities
            let item = AVPlayerItem(url: local)
            item.preferredForwardBufferDuration = 5
            player.replaceCurrentItem(with: item)
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
              Task { @MainActor in
                guard let self, let item, self.generation == token, self.player.currentItem === item else { return }
                if item.status == .readyToPlay { self.watchdog?.cancel(); self.loading = false; if playing { self.player.play() } }
                else if item.status == .failed { self.loading = false; self.error = "直播播放中断，请重试"; self.activity.setPlaying(false) }
              }
            }
            watchdog = Task { [weak self] in
              do { try await Task.sleep(for: .seconds(25)) } catch { return }
              guard let self, self.generation == token, self.loading else { return }
              self.loading = false; self.error = "直播画面尚未就绪，请重试"; self.player.pause(); self.activity.setPlaying(false)
            }
            return
          } catch {
            await relay.stop()
            if Task.isCancelled { throw CancellationError() }
            lastError = error
          }
        }
        throw lastError
      } catch {
        guard token == generation else { return }
        loading = false
        if !(error is CancellationError) { self.error = error.localizedDescription }
      }
    }
  }
  func stop() {
    generation = UUID(); task?.cancel(); task = nil; watchdog?.cancel(); watchdog = nil
    statusObservation = nil; player.pause(); player.replaceCurrentItem(with: nil)
    activity.setPlaying(false); loading = false; error = nil; qualities = [:]; quality = 0
    if let relay { Task { await relay.stop() } }; relay = nil
  }
  isolated deinit { task?.cancel(); watchdog?.cancel(); player.pause(); if let relay { Task { await relay.stop() } } }
}

struct LivePlayerPanel: View {
  @Bindable var store: Store
  let room: LiveRoom
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    let playback = store.livePlayback
    VStack(spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text(room.title).font(.headline).lineLimit(2)
          Text(room.author.isEmpty ? "直播间 \(room.id)" : room.author + " · " + room.area).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if !playback.qualities.isEmpty {
          Menu(playback.qualities[playback.quality] ?? "清晰度") {
            ForEach(playback.qualities.keys.sorted(by: >), id: \.self) { qn in
              Button(playback.qualities[qn] ?? "\(qn)") { playback.open(room, api: store.api, quality: qn, playing: playback.player.rate != 0) }
            }
          }.disabled(playback.loading)
        }
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      ZStack {
        LiveVideoView(player: playback.player)
        if playback.loading { ProgressView("正在连接直播…").padding(18).glassEffect(.regular, in: .rect(cornerRadius: 16)) }
        if let error = playback.error {
          VStack(spacing: 12) {
            Text(error).multilineTextAlignment(.center)
            Button("重试") { playback.open(room, api: store.api) }
          }.padding(20).glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
      }.background(.black).clipShape(.rect(cornerRadius: 16)).environment(\.colorScheme, .dark)
    }.padding(20).frame(minWidth: 860, idealWidth: 1040, minHeight: 580, idealHeight: 700)
      .background { GlassBackdrop() }.appAppearance().tint(biliPink).buttonStyle(.glass)
      .task(id: room.id) { playback.open(room, api: store.api) }
      .onDisappear { playback.stop() }
  }
}

private struct LiveVideoView: NSViewRepresentable {
  let player: AVPlayer
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.controlsStyle = .inline; view.showsFullScreenToggleButton = true
    view.allowsPictureInPicturePlayback = true; view.allowsVideoFrameAnalysis = false
    view.preferredDisplayDynamicRange = .automatic; view.player = player
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
