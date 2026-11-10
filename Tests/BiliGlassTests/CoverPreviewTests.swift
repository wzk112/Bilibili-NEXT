import AVKit
import AppKit
import Foundation
import Testing
import SwiftUI
@testable import BiliGlass

@Suite(.serialized) @MainActor struct CoverPreviewTests {
  private var fixture: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Vendor/BiliKitCore/Tests/BiliPlaybackTests/Fixtures/video-avc.mp4")
  }
  private func video(_ id: String) -> Video { Video(bvid: id, title: id, cover: "", author: "", duration: 20, views: 0) }
  private func waitFor(_ predicate: () -> Bool) async {
    for _ in 0..<100 where !predicate() { try? await Task.sleep(for: .milliseconds(5)) }
  }

  @Test func leavingBeforeHoverDelayDoesNotFetchAnything() async throws {
    var requests = 0
    let model = CoverPreview(delay: .milliseconds(80), prepare: { _ in
      requests += 1
      return CoverPreviewSource(url: fixture, cid: 1, stop: {})
    })
    model.hover(video("a"))
    try await Task.sleep(for: .milliseconds(10))
    model.stop(videoID: "a")
    try await Task.sleep(for: .milliseconds(100))
    #expect(requests == 0 && model.activeID == nil && model.player.currentItem == nil)
  }

  @Test func switchingAndLeavingReleaseSessionsWithoutAnOldCardStoppingTheNewOne() async throws {
    var stopped: [String] = []
    let model = CoverPreview(delay: .zero, prepare: { video in
      CoverPreviewSource(url: fixture, cid: 1, stop: { stopped.append(video.bvid) })
    })
    defer { model.stop() }
    model.hover(video("a")); await waitFor { model.activeID == "a" }
    #expect(model.activeID == "a")
    model.displayed(model.identity)
    #expect(model.player.isMuted && model.player.volume == 0)
    #expect(!model.player.preventsDisplaySleepDuringVideoPlayback)
    model.hover(video("b")); await waitFor { model.activeID == "b" }
    model.displayed(model.identity)
    #expect(stopped == ["a"])
    model.stop(videoID: "a")
    #expect(model.activeID == "b" && model.player.currentItem != nil)
    model.stop(videoID: "b")
    #expect(stopped == ["a", "b"])
    #expect(model.activeID == nil && model.hoveredID == nil && !model.ready)
    #expect(model.player.currentItem == nil && model.player.rate == 0 && model.comments.isEmpty)
  }

  @Test func latePreparationCannotReplaceTheNextCoverAndItsLeaseIsClosed() async throws {
    var gate: CheckedContinuation<Void, Never>?
    var stopped: [String] = []
    let model = CoverPreview(delay: .zero, prepare: { video in
      if video.bvid == "a" { await withCheckedContinuation { gate = $0 } }
      return CoverPreviewSource(url: fixture, cid: 1, stop: { stopped.append(video.bvid) })
    })
    defer { gate?.resume(); model.stop() }
    model.hover(video("a")); await waitFor { gate != nil }
    try #require(gate != nil)
    model.hover(video("b")); await waitFor { model.activeID == "b" }
    model.displayed(model.identity)
    gate?.resume(); gate = nil
    await waitFor { stopped.contains("a") }
    #expect(model.activeID == "b" && stopped == ["a"])
  }

  @Test func previewDanmakuIsSparseBasicAndRespectsBlocking() {
    var items: [Danmaku] = []
    for index in 0..<120 {
      let mode: Int = index % 3 == 0 ? 5 : 1
      let text: String = index % 2 == 0 ? "屏蔽" : "保留"
      items.append(Danmaku(id: String(index), time: Double(index) / 4, mode: mode,
        size: 25, color: 0xFFFFFF, text: text))
    }
    let sampled = CoverPreview.sampleComments(items, options: DanmakuDisplayOptions(blockedWords: ["屏蔽"]))
    #expect(!sampled.isEmpty && sampled.count <= 6)
    #expect(sampled.allSatisfy { $0.mode == 1 && $0.time < 15 && $0.text == "保留" })
    for lane in 0..<2 {
      let times = sampled.enumerated().filter { $0.offset % 2 == lane }.map { $0.element.time }
      #expect(zip(times, times.dropFirst()).allSatisfy { pair in pair.1 - pair.0 >= 5 })
    }
  }


  @Test func previewRendersInItsOwnLayerAndLeavingReleasesTheMedia() async throws {
    _ = NSApplication.shared
    let model = CoverPreview(delay: .zero, prepare: { _ in
      CoverPreviewSource(url: fixture, cid: 1, stop: {})
    })
    defer { model.stop() }
    model.hover(video("render-fixture"))
    await waitFor { model.activeID != nil }
    #expect(model.activeID == "render-fixture")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: CoverPreviewOverlay(preview: model, token: model.identity))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    for _ in 0..<300 where !model.ready || model.position < 0.1 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.ready && model.position > 0.1)
    #expect(model.player.isMuted && model.player.volume == 0)
    #expect(host.bounds.size == NSSize(width: 320, height: 180))
    model.stop(videoID: "render-fixture")
    #expect(!model.ready && model.activeID == nil && model.player.currentItem == nil)
  }
}
