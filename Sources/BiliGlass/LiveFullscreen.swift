#if os(macOS)
import AVKit
import AppKit
import SwiftUI

/// One live room showing fullscreen on the main window. The sheet is dismissed
/// first because an attached sheet cannot expand with its parent's full screen.
@MainActor @Observable final class LiveFullscreenController {
  private(set) var isPresented = false
  private(set) var model: LiveRoomModel?
  /// Handed back to the catalog page so the room sheet can be restored on exit.
  private(set) var returnedModel: LiveRoomModel?
  @ObservationIgnored private var host: LiveFullscreenHost?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var enterTask: Task<Void, Never>?
  @ObservationIgnored private var exitRequested = false
  @ObservationIgnored private var ownsFullscreen = false
  private enum Phase { case closed, waitingForSheet, entering, open, exiting }
  @ObservationIgnored private var phase = Phase.closed
  @ObservationIgnored let sheetPollInterval: Duration
  @ObservationIgnored let entryTimeout: Duration
  init(sheetPollInterval: Duration = .milliseconds(50), entryTimeout: Duration = .seconds(3)) {
    self.sheetPollInterval = sheetPollInterval
    self.entryTimeout = entryTimeout
  }
  /// Returns false when no window can host the fullscreen layer; the caller then
  /// keeps the sheet open instead of leaving the room with nowhere to render.
  @discardableResult
  func open(model: LiveRoomModel, window: NSWindow?) -> Bool {
    guard phase == .closed else { return false }
    let target = window?.sheetParent ?? window ?? NSApp?.keyWindow?.sheetParent ?? NSApp?.keyWindow
    guard let host = LiveFullscreenHost(window: target) else { return false }
    returnedModel?.stop()
    host.prepareBlack()
    model.handedToFullscreen = true
    self.host = host; self.model = model
    returnedModel = nil
    exitRequested = false
    ownsFullscreen = !host.isFullScreen
    isPresented = true
    observe(host)
    phase = .waitingForSheet
    enterTask = Task { @MainActor [weak self] in
      guard let self else { return }
      // Let the sheet's dismissal animation detach it before the window grows.
      // Waiting matters even when the window is already fullscreen: the old
      // sheet's onDisappear must not run after the room has been handed back.
      while host.isSheetPresented, !Task.isCancelled {
        try? await Task.sleep(for: sheetPollInterval)
      }
      guard !Task.isCancelled, phase == .waitingForSheet else { return }
      if exitRequested || !ownsFullscreen {
        phase = .open
        if exitRequested { close() }
        return
      }
      phase = .entering
      host.toggleFullScreen()
      try? await Task.sleep(for: entryTimeout)
      guard !Task.isCancelled, phase == .entering else { return }
      if host.isFullScreen {
        phase = .open
        if exitRequested { close() }
      } else {
        finishExit(restoreModel: model)
      }
    }
    return true
  }
  func close() {
    guard isPresented else { return }
    switch phase {
    case .closed, .exiting: return
    case .waitingForSheet, .entering:
      exitRequested = true
    case .open:
      exitRequested = true
      if ownsFullscreen, let host, host.isFullScreen {
        phase = .exiting
        host.toggleFullScreen()
      } else {
        finishExit(restoreModel: model)
      }
    }
  }
  /// The catalog page consumes this once and re-presents the sheet.
  func takeReturnedModel() -> LiveRoomModel? {
    defer { returnedModel = nil }
    return returnedModel
  }
  private func observe(_ host: LiveFullscreenHost) {
    observers.append(host.observe(NSWindow.didEnterFullScreenNotification) { [weak self] in
      guard let self, phase == .entering || phase == .waitingForSheet else { return }
      phase = .open
      if exitRequested { close() }
    })
    observers.append(host.observe(NSWindow.willExitFullScreenNotification) { [weak self] in
      if self?.phase == .open { self?.phase = .exiting }
    })
    observers.append(host.observe(NSWindow.didExitFullScreenNotification) { [weak self] in
      guard let self, phase == .open || phase == .exiting else { return }
      finishExit(restoreModel: model)
    })
    observers.append(host.observe(NSWindow.willCloseNotification) { [weak self] in
      guard let self, isPresented else { return }
      finishExit(restoreModel: model, stopPlayback: true)
    })
  }
  private func finishExit(restoreModel: LiveRoomModel?, stopPlayback: Bool = false) {
    enterTask?.cancel(); enterTask = nil
    observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    host?.restoreBackground()
    if stopPlayback {
      restoreModel?.handedToFullscreen = false
      restoreModel?.stop()
    } else if let restoreModel {
      restoreModel.handedToFullscreen = false
      returnedModel = restoreModel
    }
    model = nil; host = nil
    isPresented = false; phase = .closed; exitRequested = false; ownsFullscreen = false
  }
  isolated deinit {
    enterTask?.cancel()
    observers.forEach(NotificationCenter.default.removeObserver)
  }
}

/// Window surface the controller drives; tests use `init()` to avoid a real window.
@MainActor final class LiveFullscreenHost {
  private weak var window: NSWindow?
  private var previousBackground: NSColor?
  init?(window: NSWindow?) {
    guard window != nil else { return nil }
    self.window = window
  }
  var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }
  var isSheetPresented: Bool { window?.attachedSheet != nil }
  func prepareBlack() {
    guard let window else { return }
    previousBackground = window.backgroundColor
    window.backgroundColor = .black
  }
  func restoreBackground() {
    if let previousBackground { window?.backgroundColor = previousBackground }
    previousBackground = nil
  }
  func toggleFullScreen() { window?.toggleFullScreen(nil) }
  func observe(_ name: Notification.Name, action: @escaping @MainActor () -> Void) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
      MainActor.assumeIsolated { action() }
    }
  }
}

/// Reports the sheet window so fullscreen can resolve its parent before dismissal.
struct LiveWindowReader: NSViewRepresentable {
  var onWindow: (NSWindow?) -> Void
  func makeNSView(context: Context) -> Report { Report() }
  func updateNSView(_ view: Report, context: Context) {
    view.onWindow = onWindow
    let window = view.window
    DispatchQueue.main.async { onWindow(window) }
  }
  static func dismantleNSView(_ view: Report, coordinator: ()) { view.onWindow = nil }
  final class Report: NSView {
    var onWindow: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindow?(window)
    }
  }
}

struct LiveVideoSurface: NSViewRepresentable {
  let player: AVPlayer
  func makeNSView(context: Context) -> LiveVideoView { LiveVideoView(player: player) }
  func updateNSView(_ view: LiveVideoView, context: Context) { view.player = player }
}

final class LiveVideoView: NSView {
  private let videoLayer = AVPlayerLayer()
  var player: AVPlayer? {
    get { videoLayer.player }
    set { videoLayer.player = newValue }
  }
  init(player: AVPlayer) {
    super.init(frame: .zero)
    wantsLayer = true
    videoLayer.videoGravity = .resizeAspect
    videoLayer.player = player
    layer?.addSublayer(videoLayer)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    videoLayer.frame = bounds
    CATransaction.commit()
  }
}

struct LiveFullscreenContent: View {
  @Bindable var model: LiveRoomModel
  let canSend: Bool
  let close: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var keys = LiveRoomKeys()
  @State private var visible = true
  @State private var hoveringControls = false
  @State private var adjustingVolume = false
  @State private var lastInteraction = Date()
  @State private var cursor = FullscreenCursor()
  @FocusState private var composerFocused: Bool
  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      LiveVideoSurface(player: model.player)
        .ignoresSafeArea()
      if model.danmakuEnabled {
        LiveDanmakuOverlay(messages: model.messages).allowsHitTesting(false).ignoresSafeArea()
      }
      LiveClickRegion(onInteraction: wake, onSingleClick: { model.togglePlayback() }, onDoubleClick: close)
        .ignoresSafeArea()
      if model.loading {
        ProgressView("正在加载直播").padding(16).background(.regularMaterial, in: .rect(cornerRadius: 12))
      }
      if let error = model.error {
        VStack(spacing: 12) {
          Text(error).multilineTextAlignment(.center)
          Button("重试") { Task { await model.loadPlayback(model.quality) } }
        }.padding(20).background(.regularMaterial, in: .rect(cornerRadius: 12)).padding(20)
      }
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Text(model.info.title).font(.headline).lineLimit(1)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .appGlassEffect(.regular, in: .rect(cornerRadius: 16))
            .allowsHitTesting(false)
          Spacer(minLength: 0)
          Button(action: close) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
            .buttonStyle(.pointerGlass).help("退出全屏").accessibilityLabel("退出直播全屏")
            .accessibilityIdentifier("live-exit-fullscreen")
            .padding(10).appGlassEffect(.regular, in: .rect(cornerRadius: 16))
        }
        Spacer().allowsHitTesting(false)
        HStack(spacing: 10) { playbackButton; quality; danmakuToggle; composer; Spacer(); volume }
          .buttonStyle(.appGlassButton)
          .padding(12).appGlassEffect(.regular, in: .rect(cornerRadius: 16))
          .onHover { hoveringControls = $0; if $0 { wake() } }
      }.padding(24).opacity(visible ? 1 : 0).allowsHitTesting(visible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: visible)
    }.environment(\.colorScheme, .dark).tint(biliPink)
      .onContinuousHover { phase in if case .active = phase { wake() } else { cursor.reveal() } }
      .background(LiveWindowReader { keys.window = $0 })
      .onAppear {
        keys.onEscape = close
        keys.onFullscreen = close
        keys.onTogglePlayback = { model.togglePlayback() }
        keys.onVolume = { model.adjustVolume(by: $0) }
        keys.onWake = wake
        keys.install()
      }
      .onDisappear { keys.stop(); cursor.reveal() }
      .task {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(0.5))
          guard !Task.isCancelled else { return }
          if !model.isPlaying {
            if !visible { visible = true }
          } else if visible && !hoveringControls && !adjustingVolume && !composerFocused,
            Date().timeIntervalSince(lastInteraction) > 3 {
            visible = false
          }
          let window = NSApp.keyWindow
          cursor.update(controlsVisible: visible, playing: model.isPlaying,
            activeWindow: NSApp.isActive && window?.isKeyWindow == true,
            pointerInside: window?.frame.contains(NSEvent.mouseLocation) == true, window: window)
        }
      }
  }
  private var playbackButton: some View {
    Button { wake(); model.togglePlayback() } label: {
      Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20, height: 20)
    }
      .accessibilityLabel("播放或暂停直播").accessibilityValue(model.isPlaying ? "正在播放" : "已暂停")
  }
  private var quality: some View {
    Menu {
      ForEach(model.qualities) { choice in
        Button { wake(); model.selectQuality(choice.id) } label: {
          if model.quality == choice.id { Label(choice.title, systemImage: "checkmark") } else { Text(choice.title) }
        }
      }
    } label: { Label(model.qualityTitle, systemImage: "slider.horizontal.3") }
      .disabled(model.qualities.isEmpty).fixedSize(horizontal: true, vertical: false)
  }
  private var danmakuToggle: some View {
    Button { wake(); model.danmakuEnabled.toggle() } label: {
      Image(systemName: model.danmakuEnabled ? "text.bubble.fill" : "text.bubble")
    }.help(model.danmakuEnabled ? "关闭画面弹幕" : "开启画面弹幕")
      .accessibilityLabel(model.danmakuEnabled ? "关闭画面弹幕" : "开启画面弹幕")
  }
  private var composer: some View {
    HStack(spacing: 8) {
      TextField(canSend ? "发送弹幕" : "登录后发送弹幕", text: $model.draft)
        .textFieldStyle(.roundedBorder).frame(width: 240)
        .focused($composerFocused)
        .onSubmit { wake(); Task { await model.send() } }.disabled(!canSend)
      Button("发送") { wake(); Task { await model.send() } }.buttonStyle(.appGlassProminent)
        .disabled(!canSend || model.sending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.draft.count > 100)
      if let message = model.actionMessage {
        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
  private var volume: some View {
    HStack(spacing: 8) {
      Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2")
      // A fixed width: an unconstrained slider collapses inside `fixedSize`.
      Slider(value: $model.volume, in: 0...1) { editing in
        adjustingVolume = editing; if editing { wake() }
      }
        .frame(width: 160).accessibilityLabel("直播音量")
    }.fixedSize()
  }
  private func wake() { cursor.reveal(); lastInteraction = Date(); visible = true }
}

/// A single click waits out the double-click interval, so a double click never
/// toggles playback on its way to the fullscreen change.
struct LiveClickRegion: NSViewRepresentable {
  var onInteraction: (() -> Void)?
  var onSingleClick: (() -> Void)?
  var onDoubleClick: () -> Void
  func makeNSView(context: Context) -> ClickView { ClickView(frame: .zero) }
  func updateNSView(_ view: ClickView, context: Context) {
    view.onInteraction = onInteraction
    view.onSingleClick = onSingleClick
    view.onDoubleClick = onDoubleClick
  }
  static func dismantleNSView(_ view: ClickView, coordinator: ()) { view.cancelPendingClick() }
  final class ClickView: NSView {
    var onInteraction: (() -> Void)?
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var tracksPrimaryClick = false
    private var pendingClick: Task<Void, Never>?
    func cancelPendingClick() { pendingClick?.cancel(); pendingClick = nil }
    override func mouseDown(with event: NSEvent) {
      tracksPrimaryClick = !event.modifierFlags.contains(.control)
      onInteraction?()
    }
    override func mouseDragged(with event: NSEvent) { tracksPrimaryClick = false }
    override func mouseUp(with event: NSEvent) {
      defer { tracksPrimaryClick = false }
      guard tracksPrimaryClick, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
      switch event.clickCount {
      case 1:
        guard onSingleClick != nil else { return }
        cancelPendingClick()
        pendingClick = Task { @MainActor [weak self] in
          do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) } catch { return }
          self?.pendingClick = nil
          self?.onSingleClick?()
        }
      case 2:
        cancelPendingClick()
        onDoubleClick?()
      default: break
      }
    }
  }
}

/// Live room shortcuts for the sheet and the fullscreen layer. An event monitor
/// runs before the window's key handling, so fullscreen Escape never reaches the
/// sheet's close action. Escape passes through when `onEscape` is nil.
@MainActor @Observable final class LiveRoomKeys {
  var window: NSWindow?
  var onEscape: (() -> Void)?
  var onFullscreen: (() -> Void)?
  var onTogglePlayback: (() -> Void)?
  var onVolume: ((Double) -> Void)?
  var onWake: (() -> Void)?
  @ObservationIgnored private var monitor: Any?
  func install() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let handled = MainActor.assumeIsolated { self?.handle(event) == true }
      return handled ? nil : event
    }
  }
  func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
  func handle(_ event: NSEvent) -> Bool {
    guard let window, event.window === window, window.isKeyWindow,
      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
    if event.keyCode == 53 { // Escape
      guard let onEscape else { return false }
      onWake?()
      if !event.isARepeat { onEscape() }
      return true
    }
    if editingText(in: window) { return false }
    switch event.keyCode {
    case 49: // Space
      if window.firstResponder is NSControl { return false }
      onWake?()
      if !event.isARepeat { onTogglePlayback?() }
      return true
    case 126, 125: // Up / down arrow
      onWake?()
      onVolume?(event.keyCode == 126 ? 0.05 : -0.05)
      return true
    default:
      guard event.charactersIgnoringModifiers?.lowercased() == "f", let onFullscreen else { return false }
      onWake?()
      if !event.isARepeat { onFullscreen() }
      return true
    }
  }
  private func editingText(in window: NSWindow) -> Bool {
    window.firstResponder is NSTextView || window.firstResponder is NSTextField
  }
  isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
#endif
