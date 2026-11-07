import AVKit

@MainActor final class PlayerKeyboard {
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
  private func handle(_ event: NSEvent) -> NSEvent? {
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
      if !event.isARepeat { cancelHeldKey(); toggle() }
      return nil
    }
    switch event.keyCode {
    case 49:
      if !event.isARepeat { cancelHeldKey(); playback.togglePlayback() }
      return nil
    case 123:
      if !event.isARepeat { playback.seekBy(-5) }
      return nil
    case 124:
      guard !rightDown, !event.isARepeat else { return nil }
      rightDown = true
      holdTask = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
        guard let self, self.rightDown, !self.editingText, let view = self.view,
          self.playback?.nativeView === view, view.handlesPlaybackShortcuts, view.window?.isKeyWindow == true else { return }
        self.boosted = self.playback?.beginTemporarySpeed() ?? false
      }
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
