import AVKit
import SwiftUI

@MainActor @Observable final class FullscreenPlayerController {
  private(set) var isPresented = false
  @ObservationIgnored private weak var window: NSWindow?
  @ObservationIgnored private weak var playback: Playback?
  @ObservationIgnored private var previousBackground: NSColor?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  private enum Phase { case closed, entering, open, exiting }
  private var phase = Phase.closed
  private var ownsFullscreen = false
  private var exitRequested = false
  func toggle(store: Store) { isPresented ? close() : open(store: store) }
  func open(store: Store) {
    guard phase == .closed, let window = store.playback.nativeView?.window ?? NSApp.keyWindow else { return }
    self.window = window; playback = store.playback
    previousBackground = window.backgroundColor; window.backgroundColor = .black
    ownsFullscreen = !window.styleMask.contains(.fullScreen)
    exitRequested = false
    phase = ownsFullscreen ? .entering : .open
    store.playback.isFullscreen = true
    isPresented = true
    observe(NSWindow.didEnterFullScreenNotification, window: window) { controller in
      controller.phase = .open
      if controller.exitRequested { controller.close() }
    }
    observe(NSWindow.willExitFullScreenNotification, window: window) { $0.phase = .exiting }
    observe(NSWindow.didExitFullScreenNotification, window: window) { $0.restore() }
    observe(NSWindow.willCloseNotification, window: window) { $0.restore() }
    if ownsFullscreen {
      // One system transition on the existing window; no second window or zoom animation.
      DispatchQueue.main.async { [weak self, weak window] in
        guard self?.phase == .entering else { return }
        window?.toggleFullScreen(nil)
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .seconds(3))
          guard let self, self.phase == .entering else { return }
          if self.window?.styleMask.contains(.fullScreen) == true { self.phase = .open; if self.exitRequested { self.close() } }
          else { self.restore() }
        }
      }
    }
  }
  func close() {
    guard isPresented, phase != .exiting else { return }
    if phase == .entering { exitRequested = true; return }
    if ownsFullscreen, let window, window.styleMask.contains(.fullScreen) {
      phase = .exiting
      window.toggleFullScreen(nil)
    } else { restore() }
  }
  private func observe(_ name: Notification.Name, window: NSWindow,
                       action: @escaping @MainActor (FullscreenPlayerController) -> Void) {
    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { if let self { action(self) } }
    })
  }
  private func restore() {
    observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    if let previousBackground { window?.backgroundColor = previousBackground }
    previousBackground = nil
    playback?.isFullscreen = false
    isPresented = false; phase = .closed; exitRequested = false
    window = nil; playback = nil
  }
  isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
struct FullscreenPlayerContent: View {
  @Bindable var store: Store
  let close: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var visible = true
  @State private var hoveringControls = false
  @State private var adjustingPlayback = false
  @State private var danmakuSettingsPresented = false
  @State private var lastInteraction = Date()
  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      NativePlayer(playback:store.playback,items:store.danmaku.items,enabled:store.danmaku.enabled,fullscreen:true,toggleFullscreen:close)
        .ignoresSafeArea()
      VideoSurfaceClickTarget(playback: store.playback, toggleFullscreen: close, onInteraction: wake)
        .ignoresSafeArea()
      PlaybackStatusOverlay(playback: store.playback)
      SubtitleOverlay(extras: store.extras, playback: store.playback, fullscreen: true)
      if store.playback.isBoosting {
        Text(store.playback.boostLabel).padding(12).glassEffect(.regular, in: .capsule).frame(maxHeight: .infinity, alignment: .top).padding(.top, 24).allowsHitTesting(false)
      }
      VStack(spacing:0) {
        HStack {
          Text(store.playback.detail?.video.title ?? "播放").font(.headline).lineLimit(2)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
          Spacer(minLength: 0)
        }.allowsHitTesting(false)
        Spacer().allowsHitTesting(false)
        PlayerControls(playback: store.playback, fullscreen: true, toggleFullscreen: close, extras: store.extras,
          onEditingChanged: { adjustingPlayback = $0 },
          nextAction: store.hasNextVideo ? { store.playNext() } : nil) {
          HStack(spacing: 10) {
            Toggle("弹幕", isOn: $store.danmaku.enabled).toggleStyle(.switch).fixedSize()
            DanmakuSettingsButton(onPresentationChange: { danmakuSettingsPresented = $0 })
            Menu("字幕") {
              Button("关闭字幕") { Task { await store.extras.selectSubtitle("", api: store.api) } }
              ForEach(store.extras.subtitles) { track in
                Button(track.title) { Task { await store.extras.selectSubtitle(track.id, api: store.api) } }
              }
            }
            PlaybackQualityMenu(store: store)
            PlaybackSpeedMenu(playback: store.playback)
          }.buttonStyle(.glass)
        }
          .frame(maxWidth: 1400)
          .onHover { hoveringControls = $0; if $0 { wake() } }
      }.padding(24).opacity(visible ? 1:0).allowsHitTesting(visible)
        .animation(reduceMotion ? nil : .easeInOut(duration:0.18),value:visible)
      PlaybackDetailsOverlay(playback: store.playback, topInset: 24, bottomInset: 100)
      Button("") { close() }.keyboardShortcut(.cancelAction).hidden()
    }.environment(\.colorScheme, .dark).tint(biliPink)
      .onContinuousHover { phase in if case .active = phase { wake() } }
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for:.seconds(0.5))
          guard !Task.isCancelled else { return }
          if store.playback.player.rate == 0 { if !visible { visible = true } }
          else if visible && !hoveringControls && !adjustingPlayback && !danmakuSettingsPresented
            && Date().timeIntervalSince(lastInteraction) > 3 { visible = false }
        }
      }
  }
  private func wake() { lastInteraction = Date(); visible = true }
}
