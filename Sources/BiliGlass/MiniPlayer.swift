import AVKit
import SwiftUI

struct MiniPlayer: View {
  @Bindable var store: Store
  var onReturn: (() -> Void)?
  var onClose: (() -> Void)?
  var returnLabel = "返回播放页"
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(store.playback.isPlaying ? "正在播放" : "已暂停", systemImage: "play.rectangle").font(.caption.weight(.medium)).foregroundStyle(.primary.opacity(0.85))
        Spacer()
        Button(action: onClose ?? store.closeMiniPlayer) { Image(systemName: "xmark") }
          .buttonStyle(.plain).help("关闭迷你播放器").accessibilityLabel("关闭迷你播放器")
      }
      ZStack {
        MiniPlayerVideo(playback: store.playback)
        PlaybackStatusOverlay(playback: store.playback)
        Color.clear.contentShape(.rect).onTapGesture(perform: onReturn ?? store.returnToPlayer).accessibilityLabel(returnLabel)
      }.frame(height: 169).background(.black).clipShape(.rect(cornerRadius: 12))
      Text(store.playback.detail?.video.title ?? "正在载入视频…").font(.callout.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      HStack {
        Button { store.playback.togglePlayback() } label: {
          Image(systemName: store.playback.isPlaying ? "pause.fill" : "play.fill")
        }.help(store.playback.isPlaying ? "暂停" : "继续播放").accessibilityLabel(store.playback.isPlaying ? "暂停迷你播放器" : "继续播放迷你播放器")
          .disabled(store.playback.player.currentItem == nil)
        Spacer()
        Button(action: onReturn ?? store.returnToPlayer) { Label(returnLabel, systemImage: "arrow.up.left.square") }
      }.buttonStyle(.glass)
    }.padding(12).frame(width: 324).foregroundStyle(.primary)
      // Regular glass blurs text underneath while retaining background color
      // and native refraction. An opaque backplate would lose that transparency.
      .glassEffect(.regular, in: .rect(cornerRadius: 22))
      .accessibilityElement(children: .contain).accessibilityLabel("迷你播放器")
  }
}

/// Reuses the existing AVPlayer. Moving between pages never replaces its item.
private struct MiniPlayerVideo: NSViewRepresentable {
  let playback: Playback
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView(frame: .zero)
    view.controlsStyle = .none; view.allowsVideoFrameAnalysis = false
    view.videoGravity = .resizeAspect; view.preferredDisplayDynamicRange = .high
    view.player = playback.player
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== playback.player { view.player = playback.player }
  }
  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
