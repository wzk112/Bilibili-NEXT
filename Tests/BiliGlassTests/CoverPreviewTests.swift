import AVFoundation
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

  @Test func secondaryClickCopiesTheFullTitleAndPrimaryClickDoesNot() throws {
    let title = "这是完整标题，包括卡片两行中放不下的后半部分"
    var copied: [String] = []
    let view = TitleCopyRegion.CopyView()
    view.copyTitle = { copied.append(title) }
    func event(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags,
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    view.mouseDown(with: try event(.leftMouseDown))
    #expect(copied.isEmpty)
    view.rightMouseDown(with: try event(.rightMouseDown))
    view.mouseDown(with: try event(.leftMouseDown, flags: .control))
    #expect(copied == [title, title])
  }

  @Test func titlesInsideSeparateCardsOnlyConsumeClicksWithinTheirOwnBounds() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: VStack {
      ForEach(0..<2) { index in
        Button {} label: {
          VStack {
            Color.gray.frame(height: 70)
            Text("title-\(index)").frame(width: 300, height: 38)
              .copyableVideoTitle("title-\(index)")
          }.frame(width: 300)
        }.buttonStyle(.plain).contextMenu { Button("播放") {} }
      }
    })
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    try await Task.sleep(for: .milliseconds(20))
    host.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let regions = descendants(host).compactMap { $0 as? TitleCopyRegion.CopyView }
    #expect(regions.count == 2)
    var copied: [String] = []
    for region in regions { region.copyTitle = { copied.append(region.title) } }
    func route(_ type: NSEvent.EventType, point: NSPoint, flags: NSEvent.ModifierFlags = []) throws -> Bool {
      let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
      return regions.contains { $0.handleSecondaryClick(event) }
    }
    for region in regions {
      let point = region.convert(NSPoint(x: region.bounds.midX, y: region.bounds.midY), to: nil)
      copied.removeAll()
      #expect(try !route(.leftMouseDown, point: point))
      #expect(copied.isEmpty)
      #expect(try route(.rightMouseDown, point: point))
      #expect(copied == [region.title])
      copied.removeAll()
      #expect(try route(.leftMouseDown, point: point, flags: .control))
      #expect(copied == [region.title])
    }
    copied.removeAll()
    // The cover belongs to the surrounding card's context menu, never to a title.
    let title = try #require(regions.first)
    let coverPoint = title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.maxY + 20), to: nil)
    #expect(try !route(.rightMouseDown, point: coverPoint))
    #expect(copied.isEmpty)
  }
}
