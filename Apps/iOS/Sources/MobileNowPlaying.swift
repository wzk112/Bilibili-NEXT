import AVFoundation
import MediaPlayer
import UIKit
import SwiftUI

/// One command owner per playback session, including while the player UI is dismissed.
@MainActor final class MobileNowPlaying {
  private weak var store: Store?
  private let player: AVPlayer
  private var observer: Any?
  private var rateObserver: NSKeyValueObservation?
  private var commands: [(MPRemoteCommand, Any)] = []
  init(store: Store) {
    self.store = store
    player = store.playback.player
    let center = MPRemoteCommandCenter.shared()
    bind(center.playCommand) { store in store.resumePlayback() }
    bind(center.pauseCommand) { store in store.playback.pausePlayback() }
    bind(center.togglePlayPauseCommand) { store in
      if store.playback.isPlaying { store.playback.pausePlayback() } else { store.resumePlayback() }
    }
    bind(center.nextTrackCommand) { $0.next() }
    commands.append((center.changePlaybackPositionCommand,
      center.changePlaybackPositionCommand.addTarget { [weak self] event in
        guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
        let seconds = event.positionTime
        Task { @MainActor in self?.store?.playback.seek(to: seconds); self?.update() }
        return .success
      }))
    observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.update() }
    }
    rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
      Task { @MainActor in self?.update() }
    }
  }
  private func bind(_ command: MPRemoteCommand, action: @escaping @MainActor (Store) -> Void) {
    commands.append((command, command.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self, let store = self.store, store.isPlaybackOpen else { return }
        action(store); self.update()
      }
      return .success
    }))
  }
  func update() {
    let center = MPRemoteCommandCenter.shared()
    let available = store?.isPlaybackOpen == true && store?.playback.detail != nil
    center.playCommand.isEnabled = available
    center.pauseCommand.isEnabled = available
    center.togglePlayPauseCommand.isEnabled = available
    center.changePlaybackPositionCommand.isEnabled = available
    center.nextTrackCommand.isEnabled = available && store?.hasNext == true
    guard available, let store, let detail = store.playback.detail else {
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      return
    }
    let part = detail.pages.first { $0.id == store.playback.selectedCID }
    let title = detail.pages.count > 1 ? detail.video.title + " · " + (part?.title ?? "") : detail.video.title
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: detail.video.author,
      MPMediaItemPropertyPlaybackDuration: store.playback.durationSeconds,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: store.playback.positionSeconds,
      MPNowPlayingInfoPropertyPlaybackRate: player.rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: store.playback.speed,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
  }
  deinit {
    if let observer { player.removeTimeObserver(observer) }
    for (command, token) in commands { command.removeTarget(token) }
  }
}

extension Store {
  func updateBackgroundPlayback() {
    playback.player.audiovisualBackgroundPlaybackPolicy = backgroundPlaybackEnabled ? .continuesIfPossible : .pauses
    if !backgroundPlaybackEnabled && UIApplication.shared.applicationState == .background {
      playback.pausePlayback()
    }
  }
  var backgroundPlaybackEnabled: Bool {
    UserDefaults.standard.object(forKey: "backgroundPlayback") == nil || UserDefaults.standard.bool(forKey: "backgroundPlayback")
  }
  func sceneChanged(_ phase: ScenePhase) {
    updateBackgroundPlayback()
    if phase == .background && !backgroundPlaybackEnabled { playback.pausePlayback() }
    nowPlaying?.update()
  }
}
