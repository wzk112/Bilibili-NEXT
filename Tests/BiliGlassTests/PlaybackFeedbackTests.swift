import Foundation
import Testing
@testable import BiliGlass

@MainActor struct PlaybackFeedbackTests {
  @Test func replacingFeedbackCancelsOldDismissalAndStoppingClearsIt() async throws {
    let playback = Playback()
    playback.feedback.show("first", symbol: "speedometer", duration: .milliseconds(10))
    playback.feedback.show("latest", symbol: "speaker.wave.2", duration: .seconds(2))
    let latest = playback.feedback.notice?.id
    try await Task.sleep(for: .milliseconds(60))
    #expect(playback.feedback.notice?.id == latest)
    #expect(playback.feedback.notice?.title == "latest")
    playback.setVolume(0.5)
    #expect(playback.feedback.notice == nil)
    playback.feedback.show("old speed", symbol: "speedometer")
    playback.setSpeed(1.5)
    #expect(playback.feedback.notice == nil)
    playback.feedback.show("last", symbol: "speaker.wave.2")
    playback.stop()
    #expect(playback.feedback.notice == nil)
  }

  @Test func feedbackExpiresWithoutPlaybackProgressOrMouseMovement() async throws {
    let feedback = PlaybackFeedback()
    feedback.show("1.25×", symbol: "speedometer", duration: .milliseconds(20))
    for _ in 0..<150 {
      if feedback.notice == nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(feedback.notice == nil)
  }
}
