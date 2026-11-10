import AppKit
import AVKit
import SwiftUI
import Testing
@testable import BiliGlass

@MainActor struct MacPlaybackRuntimeTests {
  @Test func localRenderedPlaybackPauseSeekTimerAndCleanup() async throws {
    _ = NSApplication.shared
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Vendor/BiliKitCore/Tests/BiliPlaybackTests/Fixtures/video-avc.mp4")
    let playback = Playback()
    playback.player.isMuted = true
    playback.persistQualityPreference = false
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { playback.stop(); window.close() }
    let host = NSHostingView(rootView: NativePlayer(playback: playback, items: [], enabled: false))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let video = Video(bvid: "local-only-probe", title: "fixture", cover: "", author: "", duration: 2, views: 0)
    playback.openLocal(fixture, video: video, restoring: PlaybackResume(position: 0, playing: true))
    for _ in 0..<400 where !playback.renderedFrame || playback.positionSeconds < 0.1 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(playback.renderedFrame && playback.positionSeconds > 0.1)
    #expect(!playback.bufferedRanges.isEmpty)
    playback.pausePlayback()
    #expect(playback.player.rate == 0)
    playback.seek(to: 0.2)
    try await Task.sleep(for: .milliseconds(100))
    #expect(playback.player.rate == 0)
    playback.continuePlayback()
    #expect(playback.player.rate > 0)
    playback.sleepTimer.start(after: 0.05)
    try await Task.sleep(for: .milliseconds(150))
    #expect(playback.player.rate == 0 && playback.sleepTimer.mode == nil)
    playback.stop()
    #expect(playback.player.currentItem == nil && playback.bufferedRanges.isEmpty)
  }
}
