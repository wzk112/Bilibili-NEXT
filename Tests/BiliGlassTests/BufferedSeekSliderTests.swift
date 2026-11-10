import AppKit
import AVFoundation
import SwiftUI
import Testing
@testable import BiliGlass

struct PlaybackBufferRangeTests {
  @Test func playableRangesClipMergeAndKeepRealHoles() {
    func range(_ start: Double, _ duration: Double) -> CMTimeRange {
      CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
        duration: CMTime(seconds: duration, preferredTimescale: 600))
    }
    let ranges = [range(50, 30), range(-5, 25), range(10, 15), range(90, 30), range(120, 10), range(5, 0), .invalid]
    #expect(PlaybackBufferRange.playable(ranges, duration: 100) == [
      .init(start: 0, end: 0.25), .init(start: 0.5, end: 0.8), .init(start: 0.9, end: 1)])
    #expect(PlaybackBufferRange.playable(ranges, duration: .infinity).isEmpty)
    #expect(PlaybackBufferRange.playable(ranges, duration: 0).isEmpty)
  }
}

@MainActor struct BufferedSeekSliderTests {
  @Test func nativeAccessibilityChangesCommitToSeekBinding() throws {
    let app = NSApplication.shared
    _ = app
    var value = 15.0
    let host = NSHostingView(rootView: BufferedSeekSlider(value: Binding(get: { value }, set: { value = $0 }),
      duration: 100, buffered: [.init(start: 0, end: 0.5)], enabled: true, onEditingChanged: { _ in }))
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 32)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func find(_ view: NSView) -> SeekSlider? {
      (view as? SeekSlider) ?? view.subviews.lazy.compactMap(find).first
    }
    let slider = try #require(find(host))
    #expect(slider.accessibilityLabel() == "播放进度")
    _ = slider.accessibilityPerformIncrement()
    #expect(value > 15 && value <= 100)
    _ = slider.accessibilityPerformDecrement()
    #expect(abs(value - 15) < 0.01)
  }
}
