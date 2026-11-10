import AVKit

@MainActor final class PlayerKeyboard {
  static let speedChoices: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
  private weak var view: NativeVideoView?
  private weak var playback: Playback?
  private var monitor: Any?
  private var resignObserver: NSObjectProtocol?
  private var holdTask: Task<Void, Never>?
  private var rightDown = false
  private var boosted = false
  init(view: NativeVideoView, playback: Playback) {
    self.view = view; self.playback = playback
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
      let handled = MainActor.assumeIsolated {
        guard let self else { return false }
        return self.handle(event) == nil
      }
      return handled ? nil : event
    }
    resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
      object: nil, queue: .main) { [weak self] notification in
        MainActor.assumeIsolated {
          guard let self, notification.object as? NSWindow === self.view?.window else { return }
          self.cancelHeldKey()
        }
      }
  }
  private var editingText: Bool {
    let responder = view?.window?.firstResponder
    return responder is NSTextView || responder is NSTextField
  }
  func handle(_ event: NSEvent) -> NSEvent? {
    guard let view, let playback, playback.nativeView === view, view.handlesPlaybackShortcuts,
          event.window === view.window, view.window?.isKeyWindow == true,
          playback.player.currentItem != nil else { return event }
    if event.type == .keyUp, event.keyCode == 124, rightDown {
      let wasBoosted = boosted
      cancelHeldKey()
      if !wasBoosted && !editingText { playback.seekBy(5) }
      return nil
    }
    guard event.type == .keyDown, !editingText,
          event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
    if event.charactersIgnoringModifiers?.lowercased() == "f", let toggle = view.toggleFullscreen {
      if !event.isARepeat { view.keyboardInteraction?(); cancelHeldKey(); toggle() }
      return nil
    }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "[", "<":
      view.keyboardInteraction?()
      playback.setSpeed(Self.speedChoices.last(where: { $0 < playback.speed - 0.001 }) ?? Self.speedChoices[0])
      return nil
    case "]", ">":
      view.keyboardInteraction?()
      playback.setSpeed(Self.speedChoices.first(where: { $0 > playback.speed + 0.001 }) ?? Self.speedChoices.last!)
      return nil
    case "\\":
      view.keyboardInteraction?(); playback.setSpeed(1)
      return nil
    case "m":
      if !event.isARepeat { view.keyboardInteraction?(); playback.toggleMute() }
      return nil
    case "d" where view.toggleDanmaku != nil:
      if !event.isARepeat { view.keyboardInteraction?(); view.toggleDanmaku?() }
      return nil
    default: break
    }
    switch event.keyCode {
    case 49:
      if !event.isARepeat { view.keyboardInteraction?(); cancelHeldKey(); playback.togglePlayback() }
      return nil
    case 123:
      if !event.isARepeat { view.keyboardInteraction?(); playback.seekBy(-5) }
      return nil
    case 124:
      guard !rightDown, !event.isARepeat else { return nil }
      view.keyboardInteraction?()
      rightDown = true
      holdTask = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard let self, self.rightDown, !self.editingText, let view = self.view,
          self.playback?.nativeView === view, view.handlesPlaybackShortcuts, view.window?.isKeyWindow == true else { return }
        self.boosted = self.playback?.beginTemporarySpeed() ?? false
      }
      return nil
    case 125, 126:
      view.keyboardInteraction?()
      playback.setVolume(playback.player.volume + (event.keyCode == 126 ? 0.05 : -0.05))
      return nil
    default: return event
    }
  }
  func cancelHeldKey() {
    let ownedBoost = boosted
    holdTask?.cancel(); holdTask = nil
    rightDown = false; boosted = false
    // Inline and fullscreen views coexist. Updating the inactive view must not
    // release the temporary speed owned by the fullscreen keyboard.
    if ownedBoost { playback?.endTemporarySpeed() }
  }
  func stop() {
    cancelHeldKey()
    if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
  }
  isolated deinit {
    holdTask?.cancel()
    if let monitor { NSEvent.removeMonitor(monitor) }
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
  }
}
