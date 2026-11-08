import AppKit

/// Scope the power assertion to active playback, including the mini player and PiP.
@MainActor final class PlaybackScreenActivity {
  private var token: NSObjectProtocol?
  private let begin: () -> NSObjectProtocol
  private let end: (NSObjectProtocol) -> Void
  var isActive: Bool { token != nil }

  init(begin: @escaping () -> NSObjectProtocol = {
    ProcessInfo.processInfo.beginActivity(options: .idleDisplaySleepDisabled,
      reason: "Bilibili NEXT video playback")
  }, end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
    self.begin = begin; self.end = end
  }

  func setPlaying(_ playing: Bool) {
    if playing {
      if token == nil { token = begin() }
    } else if let token {
      self.token = nil
      end(token)
    }
  }

  isolated deinit { if let token { end(token) } }
}

/// Own only the cursor hiding requested by this fullscreen player.
@MainActor final class FullscreenCursor {
  private let apply: (Bool) -> Void
  private let center: NotificationCenter
  private var observers: [NSObjectProtocol] = []
  private weak var window: NSWindow?
  private(set) var isHidden = false

  init(center: NotificationCenter = .default,
       apply: @escaping (Bool) -> Void = { NSCursor.setHiddenUntilMouseMoves($0) }) {
    self.center = center; self.apply = apply
    for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        MainActor.assumeIsolated {
          guard let self else { return }
          if name == NSApplication.didResignActiveNotification || note.object as? NSWindow === self.window {
            self.reveal()
          }
        }
      })
    }
  }

  func update(controlsVisible: Bool, playing: Bool, activeWindow: Bool, pointerInside: Bool, window: NSWindow? = nil) {
    self.window = window
    let hidden = !controlsVisible && playing && activeWindow && pointerInside
    guard hidden != isHidden else { return }
    isHidden = hidden
    apply(hidden)
  }

  func reveal() {
    guard isHidden else { return }
    isHidden = false
    apply(false)
  }

  isolated deinit {
    observers.forEach(center.removeObserver)
    if isHidden { apply(false) }
  }
}
