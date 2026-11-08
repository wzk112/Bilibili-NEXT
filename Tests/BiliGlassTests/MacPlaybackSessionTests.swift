import AppKit
import Testing
@testable import BiliGlass

@MainActor struct MacPlaybackSessionTests {
  @Test func playbackActivityHasOneBalancedLifetimeAcrossPauseResumeAndDestruction() {
    var began = 0
    var ended: [NSObjectProtocol] = []
    var activity: PlaybackScreenActivity? = PlaybackScreenActivity(begin: {
      began += 1; return NSObject()
    }, end: { ended.append($0) })
    #expect(activity?.isActive == false)
    activity?.setPlaying(true)
    activity?.setPlaying(true)
    #expect(began == 1 && activity?.isActive == true)
    activity?.setPlaying(false)
    activity?.setPlaying(false)
    #expect(ended.count == 1 && activity?.isActive == false)
    activity?.setPlaying(true)
    #expect(began == 2)
    activity = nil
    #expect(ended.count == 2)
    #expect(ended[0] !== ended[1])
  }

  @Test func cursorHidesOnlyForIdleActiveFullscreenAndRestoresOnDeactivation() {
    var requests: [Bool] = []
    let center = NotificationCenter()
    let cursor = FullscreenCursor(center: center, apply: { requests.append($0) })
    cursor.update(controlsVisible: true, playing: true, activeWindow: true, pointerInside: true)
    cursor.update(controlsVisible: false, playing: false, activeWindow: true, pointerInside: true)
    cursor.update(controlsVisible: false, playing: true, activeWindow: false, pointerInside: true)
    cursor.update(controlsVisible: false, playing: true, activeWindow: true, pointerInside: false)
    #expect(requests.isEmpty)
    cursor.update(controlsVisible: false, playing: true, activeWindow: true, pointerInside: true)
    cursor.update(controlsVisible: false, playing: true, activeWindow: true, pointerInside: true)
    #expect(requests == [true])
    center.post(name: NSApplication.didResignActiveNotification, object: nil)
    #expect(requests == [true, false])
    #expect(!cursor.isHidden)
    cursor.reveal()
    #expect(requests == [true, false])
  }

  @Test func closingFullscreenWhileHiddenRestoresTheCursor() {
    var requests: [Bool] = []
    var cursor: FullscreenCursor? = FullscreenCursor(center: NotificationCenter(), apply: { requests.append($0) })
    cursor?.update(controlsVisible: false, playing: true, activeWindow: true, pointerInside: true)
    cursor = nil
    #expect(requests == [true, false])
  }
}
