import AVKit
import SwiftUI

struct VideoSurfaceClickTarget: View {
  let playback: Playback
  let toggleFullscreen: () -> Void
  var onInteraction: () -> Void = {}
  @State private var firstClick: (generation: UUID, wasPlaying: Bool)?

  private var detailsTitle: String { playback.showsDetails ? "隐藏播放详情" : "播放详情" }

  var body: some View {
    VideoClickRegion(onClick: handleClick, detailsTitle: detailsTitle, onDetails: toggleDetails)
      .accessibilityLabel("视频画面")
      .accessibilityAction(named: Text("播放或暂停")) {
        onInteraction()
        playback.togglePlayback()
      }
      .accessibilityAction(named: Text(detailsTitle), toggleDetails)
  }

  private func toggleDetails() {
    onInteraction()
    playback.showsDetails.toggle()
  }

  private func handleClick(_ count: Int) {
    switch count {
    case 1:
      onInteraction()
      firstClick = (playback.generation, playback.wantsPlayback)
      playback.focusPlayer()
      playback.togglePlayback()
    case 2:
      // AppKit identifies the second click without delaying the first one.
      // Restore the playback intent before switching to fullscreen.
      if let firstClick, firstClick.generation == playback.generation,
        firstClick.wasPlaying != playback.wantsPlayback {
        if firstClick.wasPlaying { playback.continuePlayback() }
        else { playback.pausePlayback() }
      }
      firstClick = nil
      toggleFullscreen()
    default: break
    }
  }
}

private struct VideoClickRegion: NSViewRepresentable {
  var onClick: (Int) -> Void
  var detailsTitle: String
  var onDetails: () -> Void
  func makeNSView(context: Context) -> ClickView { ClickView(frame: .zero) }
  func updateNSView(_ view: ClickView, context: Context) {
    view.onClick = onClick
    view.detailsTitle = detailsTitle
    view.onDetails = onDetails
  }

  final class ClickView: NSView {
    var onClick: ((Int) -> Void)?
    var detailsTitle = ""
    var onDetails: (() -> Void)?
    private var tracksPrimaryClick = false

    override func menu(for event: NSEvent) -> NSMenu? {
      let menu = NSMenu()
      let item = NSMenuItem(title: detailsTitle, action: #selector(toggleDetails), keyEquivalent: "")
      item.target = self
      menu.addItem(item)
      return menu
    }

    @objc private func toggleDetails() { onDetails?() }

    override func mouseDown(with event: NSEvent) {
      tracksPrimaryClick = !event.modifierFlags.contains(.control)
      if !tracksPrimaryClick, let menu = menu(for: event) {
        NSMenu.popUpContextMenu(menu, with: event, for: self)
      }
    }
    override func mouseDragged(with event: NSEvent) { tracksPrimaryClick = false }
    override func mouseUp(with event: NSEvent) {
      defer { tracksPrimaryClick = false }
      guard tracksPrimaryClick, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
      onClick?(event.clickCount)
    }
  }
}

struct InlinePlaybackSurface: View {
  @Bindable var store: Store
  let isInlineVisible: Bool
  let controlsScrollMiniPlayer: Bool
  var usesCompactControls = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @State private var keyboardControlsVisible = false
  @State private var pointerInVideo = false
  @State private var pointerInControls = false
  @State private var recentlyMoved = false
  @State private var lastMovement = ContinuousClock.now
  @State private var adjustingPlayback = false
  @State private var danmakuManager = false
  @State private var danmakuSettings = false
  @State private var controlsHeight: CGFloat = 0

  private var controlsVisible: Bool {
    isInlineVisible && !store.fullscreen.isPresented
      && (voiceOverEnabled || keyboardControlsVisible || adjustingPlayback || danmakuManager
        || danmakuSettings || (pointerInVideo && (recentlyMoved || pointerInControls)))
  }

  var body: some View {
    @Bindable var dm = store.danmaku
    let playback = store.playback
    let toggleFullscreen = { store.fullscreen.open(store: store) }
    ZStack {
      NativePlayer(playback: playback, items: dm.items, enabled: dm.enabled,
        isInlineVisible: isInlineVisible, controlsScrollMiniPlayer: controlsScrollMiniPlayer,
        toggleFullscreen: toggleFullscreen)
      if isInlineVisible {
        VideoSurfaceClickTarget(playback: playback, toggleFullscreen: toggleFullscreen)
          .focusable(interactions: .activate)
          .accessibilityHint("按回车显示或隐藏播放控件")
          .onKeyPress(.return) {
            keyboardControlsVisible.toggle()
            return .handled
          }
      }
      PlaybackStatusOverlay(playback: playback)
      SubtitleOverlay(extras: store.extras, playback: playback,
        bottomInset: controlsVisible ? controlsHeight + 8 : 18)
      if playback.isBoosting {
        Label(playback.boostLabel, systemImage: "forward.fill").font(.callout).padding(10)
          .glassEffect(.regular, in: .capsule).padding(16)
          .frame(maxHeight: .infinity, alignment: .top).colorScheme(.dark).allowsHitTesting(false)
      }
    }
    .background(.black)
    .overlay(alignment: .bottom) {
      PlayerControls(playback: playback, toggleFullscreen: toggleFullscreen, extras: store.extras,
        onEditingChanged: { adjustingPlayback = $0 },
        nextAction: store.hasNextVideo ? { store.playNext() } : nil) {
        if !usesCompactControls {
          PlaybackOptionsControls(store: store,
            onSettingsPresentationChange: { danmakuSettings = $0 },
            onShowDanmakuList: { danmakuManager = true })
        }
      }
        .interfaceAnimation(usesCompactControls)
        .padding(10)
        .background {
          LinearGradient(colors: [.clear, .black.opacity(0.74)], startPoint: .top, endPoint: .bottom)
            .padding(.top, -28).allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
        .onHover { pointerInControls = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .accessibilityHidden(!controlsVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: controlsVisible)
    }
    .overlay {
      PlaybackDetailsOverlay(playback: playback, bottomInset: controlsVisible ? controlsHeight : 12)
    }
    .clipShape(.rect(cornerRadius: 16))
    .onContinuousHover { phase in
      switch phase {
      case .active:
        keyboardControlsVisible = false
        pointerInVideo = true
        recentlyMoved = true
        lastMovement = .now
      case .ended:
        pointerInVideo = false
        recentlyMoved = false
      }
    }
    .task(id: recentlyMoved) {
      guard recentlyMoved else { return }
      do {
        while ContinuousClock.now < lastMovement.advanced(by: .seconds(3)) {
          try await Task.sleep(until: lastMovement.advanced(by: .seconds(3)), clock: .continuous)
        }
        recentlyMoved = false
      } catch {}
    }
    .sheet(isPresented: $danmakuManager) { DanmakuManagement(store: store) }
    .onChange(of: usesCompactControls) { _, compact in
      if compact { danmakuSettings = false }
    }
  }
}

/// Shared options move below the video when the inline seek bar needs more room.
struct PlaybackOptionsControls: View {
  @Bindable var store: Store
  var onSettingsPresentationChange: ((Bool) -> Void)?
  var onShowDanmakuList: (() -> Void)?
  var body: some View {
    HStack(spacing: 8) {
      Toggle("弹幕", isOn: $store.danmaku.enabled).toggleStyle(.switch).fixedSize()
        .onChange(of: store.danmaku.enabled) { _, enabled in
          UserDefaults.standard.set(enabled, forKey: "danmakuEnabled")
        }
      DanmakuSettingsButton(onPresentationChange: onSettingsPresentationChange,
        onShowList: onShowDanmakuList)
      PlaybackQualityMenu(store: store)
      PlaybackSpeedMenu(playback: store.playback)
    }.buttonStyle(.glass).fixedSize(horizontal: true, vertical: false)
  }
}

struct PlayerControls<AdditionalControls: View>: View {
  let playback: Playback
  var fullscreen = false
  var toggleFullscreen: (() -> Void)?
  var extras: VideoExtras? = nil
  var onEditingChanged: ((Bool) -> Void)?
  var nextAction: (() -> Void)?
  @ViewBuilder var additionalControls: () -> AdditionalControls
  @State private var dragging = false
  @State private var position = 0.0
  @State private var hoverTime: Double?
  @State private var sliderWidth = 1.0
  @State private var controlsWidth = CGFloat.infinity
  @State private var showingVolume = false
  var body: some View {
    Group {
      let player = playback.player
      let rawDuration = playback.durationSeconds
      let duration = rawDuration.isFinite ? max(0, rawDuration) : 0
      let rawTime = playback.positionSeconds
      let current = rawTime.isFinite ? max(0, rawTime) : 0
      HStack(spacing: fullscreen ? 14 : 8) {
        Button { playback.focusPlayer(); playback.togglePlayback() } label: {
          Image(systemName: !playback.isPlaying ? "play.fill" : "pause.fill").frame(width: 20)
        }.buttonStyle(.glass).help(!playback.isPlaying ? "播放" : "暂停")
          .accessibilityLabel(!playback.isPlaying ? "播放" : "暂停")
        if let nextAction {
          Button(action: nextAction) { Image(systemName: "forward.end") }
            .buttonStyle(.glass).help("下一集").accessibilityLabel("下一集")
        }
        Text(clock(dragging ? position : current)).font(.caption.monospacedDigit()).frame(
          minWidth: 42)
        Slider(
          value: Binding(
            get: { dragging ? position : min(current, duration) },
            set: { value in
              position = value
              // Keyboard and accessibility changes do not always emit a drag
              // phase. Commit them immediately instead of snapping back.
              if !dragging { playback.seek(to: value) }
            }), in: 0...max(1, duration)
        ) { editing in
          dragging = editing
          onEditingChanged?(editing)
          if !editing {
            playback.focusPlayer()
            player.seek(
              to: CMTime(seconds: min(duration, max(0, position)), preferredTimescale: 600),
              toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
          }
        }.labelsHidden().accessibilityLabel("播放进度").disabled(duration == 0 || playback.loading)
          .onGeometryChange(for: Double.self) { $0.size.width } action: { sliderWidth = max(1, $0) }
          .onContinuousHover { phase in
            if case .active(let point) = phase { hoverTime = SeekPreviewGeometry.time(pointer: point.x, duration: duration, width: sliderWidth) } else { hoverTime = nil }
          }
          .overlay(alignment: .bottomLeading) {
            if let shots = extras?.shots, let time = dragging ? position : hoverTime {
              VideoPreview(shots: shots, time: time).offset(x: SeekPreviewGeometry.origin(time: time, duration: duration, width: sliderWidth), y: -28)
            }
          }
        Text(clock(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        additionalControls()
        Button { showingVolume.toggle() } label: { Image(systemName: "speaker.wave.2") }
          .buttonStyle(.glass).help("音量").accessibilityLabel("音量")
          .popover(isPresented: $showingVolume) {
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
              .labelsHidden().accessibilityLabel("音量").frame(width: 150).padding(16)
          }
        Slider(
            value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }),
            in: 0...1
          ) { onEditingChanged?($0) }.labelsHidden().accessibilityLabel("音量")
          .frame(width: fullscreen ? 90 : (controlsWidth < 860 ? 0 : 70))
          .opacity(!fullscreen && controlsWidth < 860 ? 0 : 1)
          .clipped().allowsHitTesting(fullscreen || controlsWidth >= 860)
          .accessibilityHidden(!fullscreen && controlsWidth < 860)
        if let toggleFullscreen {
          Button(action: toggleFullscreen) {
            Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
          }.buttonStyle(.glass).help(fullscreen ? "退出全屏" : "全屏播放")
            .accessibilityLabel(fullscreen ? "退出全屏" : "全屏播放")
        }
      }.padding(12).glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { controlsWidth = $0 }
        .interfaceAnimation(!fullscreen && controlsWidth < 860)
    }.onAppear { position = playback.positionSeconds }
      .task(id: extras?.shots?.urls.first) {
        if let url = extras?.shots?.urls.first { _ = try? await PreviewSheets.shared.image(url) }
      }
      .onChange(of: playback.positionSeconds) { _, value in if !dragging { position = value } }
      .onChange(of: showingVolume) { _, showing in onEditingChanged?(showing) }
      .onChange(of: playback.generation) { dragging = false; position = 0; onEditingChanged?(false) }
  }
  private func clock(_ seconds: Double) -> String {
    let value = Int(max(0, seconds))
    return value >= 3600
      ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
      : String(format: "%d:%02d", value / 60, value % 60)
  }
}

struct PlaybackQualityMenu: View {
  @Bindable var store: Store
  var body: some View {
    if let streams = store.playback.streams {
      Menu {
        ForEach(Array(Set(streams.videos.map(\.id))).sorted(by: >), id: \.self) { quality in
          Button {
            store.playback.selectQuality(quality, api: store.api)
          } label: {
            if quality == store.playback.selectedQuality {
              Label(streams.names[quality] ?? String(quality), systemImage: "checkmark")
            } else {
              Text(streams.names[quality] ?? String(quality))
            }
          }
        }
      } label: {
        Text(streams.names[store.playback.selectedQuality] ?? "清晰度").foregroundStyle(.primary)
      }.tint(.primary).fixedSize(horizontal: true, vertical: false)
        .help("清晰度").accessibilityLabel("清晰度")
    }
  }
}

struct PlaybackSpeedMenu: View {
  let playback: Playback
  var body: some View {
    Menu {
      ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
        Button { playback.setSpeed(Float(rate)) } label: {
          if Float(rate) == playback.speed {
            Label("\(rate.formatted())×", systemImage: "checkmark")
          } else {
            Text("\(rate.formatted())×")
          }
        }
      }
    } label: {
      Text("\(Double(playback.speed).formatted())×").foregroundStyle(.primary)
    }.tint(.primary).fixedSize(horizontal: true, vertical: false)
      .help("播放速度").accessibilityLabel("播放速度")
  }
}

enum SeekPreviewGeometry {
  static func time(pointer: Double, duration: Double, width: Double) -> Double {
    guard pointer.isFinite, duration.isFinite, width.isFinite, duration > 0, width > 16 else { return 0 }
    return min(1, max(0, (pointer - 8) / (width - 16))) * duration
  }
  static func origin(time: Double, duration: Double, width: Double, previewWidth: Double = 172) -> Double {
    guard time.isFinite, duration.isFinite, width.isFinite, duration > 0 else { return 0 }
    let x = min(1, max(0, time / duration)) * max(0, width - 16) + 8
    return max(0, min(max(0, width - previewWidth), x - previewWidth / 2))
  }
}
