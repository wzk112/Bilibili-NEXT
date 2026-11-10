import AVFoundation
import Testing
@testable import BiliGlass

@MainActor struct PlaybackSleepTimerTests {
  private var fixture: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Vendor/BiliKitCore/Tests/BiliPlaybackTests/Fixtures/video-avc.mp4")
  }
  @Test func replacingAndCancellingCountdownCannotPauseLaterPlayback() async throws {
    let timer = PlaybackSleepTimer()
    var expirations = 0
    timer.onExpire = { expirations += 1 }
    timer.start(after: 0.01)
    timer.start(after: 60)
    try await Task.sleep(for: .milliseconds(60))
    #expect(expirations == 0)
    #expect(timer.mode != nil)
    timer.cancel()
    timer.start(after: 0.02)
    for _ in 0..<150 where expirations == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(expirations == 1 && timer.mode == nil)
    timer.start(after: 0.01)
    timer.cancel()
    try await Task.sleep(for: .milliseconds(60))
    #expect(expirations == 1)
  }

  @Test func episodeEndPausesAndSuppressesLoopOrNextEpisodeButIgnoresOldItems() {
    let playback = Playback()
    defer { playback.stop() }
    let item = AVPlayerItem(url: fixture)
    playback.player.replaceCurrentItem(with: item)
    var nextRequests = 0
    playback.onEnded = { nextRequests += 1 }
    playback.sleepTimer.stopAtEnd()
    NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: AVPlayerItem(url: fixture))
    #expect(playback.sleepTimer.mode == .endOfVideo && nextRequests == 0)
    playback.screenActivity.setPlaying(true)
    NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
    #expect(playback.sleepTimer.mode == nil)
    #expect(nextRequests == 0 && !playback.screenActivity.isActive && !playback.wantsPlayback)
    NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
    #expect(nextRequests == 1)
  }

  @Test func countdownSurvivesVideoChangesAndExpiryDuringStartupPreventsAutoplay() async throws {
    let playback = Playback()
    defer { playback.stop() }
    let video = Video(bvid: "timer-fixture", title: "fixture", cover: "", author: "", duration: 2, views: 0)
    playback.sleepTimer.start(after: 60)
    let deadline = playback.sleepTimer.mode
    playback.openLocal(fixture, video: video, restoring: PlaybackResume(position: 0, playing: false))
    #expect(playback.sleepTimer.mode == deadline)
    playback.sleepTimer.stopAtEnd()
    playback.openLocal(fixture, video: video, restoring: PlaybackResume(position: 0, playing: false))
    #expect(playback.sleepTimer.mode == nil)
    playback.sleepTimer.start(after: 0.001)
    playback.openLocal(fixture, video: video, restoring: PlaybackResume(position: 0, playing: true))
    for _ in 0..<500 where playback.loading || playback.sleepTimer.mode != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(playback.error == nil && !playback.loading)
    #expect(playback.player.currentItem?.status == .readyToPlay)
    #expect(!playback.wantsPlayback && playback.player.rate == 0 && !playback.screenActivity.isActive)
    playback.sleepTimer.start(after: 60)
    playback.stop()
    #expect(playback.sleepTimer.mode == nil)
  }
}
