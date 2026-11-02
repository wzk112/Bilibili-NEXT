import CoreGraphics
import Testing
@testable import BiliGlass

struct DanmakuContinuityTests {
  @Test func rollingTextRemainsUntilItsTrailingEdgeLeavesTheViewport() throws {
    for mode in [1, 6] {
      let item = Danmaku(id: "long", time: 2, mode: mode, size: 25, color: 0xFFFFFF, text: String(repeating: "长弹幕", count: 20))
      let placement = try #require(DanmakuLayout.prepare(items: [item], size: CGSize(width: 360, height: 220), scale: 0.6, area: 1, duration: 8, time: 2).first)
      let beforeExit = placement.x(at: 9.99, viewportWidth: 360)
      if mode == 1 {
        #expect(beforeExit + placement.width > 0)
        #expect(abs(placement.x(at: 10, viewportWidth: 360) + placement.width) < 0.001)
      } else {
        #expect(beforeExit < 360)
        #expect(abs(placement.x(at: 10, viewportWidth: 360) - 360) < 0.001)
      }
    }
  }
  @Test func newlyArrivingCommentsCannotEvictAnAlreadyVisibleComment() throws {
    let original = Danmaku(id: "original", time: 1, mode: 1, size: 25, color: 0xFFFFFF, text: "必须完整滚出屏幕")
    let size = CGSize(width: 400, height: 68)
    let options = DanmakuDisplayOptions(avoidSubtitles: false)
    let first = DanmakuLayout.prepare(items: [original], size: size, scale: 1, area: 1, duration: 8, time: 1, options: options)
    #expect(first.count == 1)
    let late = Danmaku(id: "late", time: 0.8, mode: 5, size: 25, color: 0xFFFFFF, text: "迟到的顶部弹幕")
    let recomputed = DanmakuLayout.prepare(items: [late, original], size: size, scale: 1, area: 1, duration: 8, time: 2, options: options)
    #expect(!recomputed.contains { $0.item.id == original.id })
    let stable = DanmakuLayout.prepare(items: [late, original], size: size, scale: 1, area: 1, duration: 8, time: 2, options: options, retaining: first)
    let retained = try #require(stable.first { $0.item.id == original.id })
    #expect(retained.lane == first[0].lane)
    #expect(retained.x(at: 2, viewportWidth: 400) == first[0].x(at: 2, viewportWidth: 400))
  }
  @Test func inlinePhoneVideoUsesItsActualAvailableHeight() {
    let size = CGSize(width: 360, height: 202.5)
    let items = (0..<30).map { Danmaku(id: "\($0)", time: 0, mode: 1, size: 25, color: 0xFFFFFF, text: "弹幕 \($0)") }
    let old = DanmakuLayout.prepare(items: items, size: size, scale: 0.56, area: 0.5, duration: 8, time: 0, topInset: 56, bottomInset: 54)
    let insets = DanmakuLayout.mobileInsets(height: size.height, fullscreen: false)
    let updated = DanmakuLayout.prepare(items: items, size: size, scale: 0.56, area: 0.5, duration: 8, time: 0, topInset: insets.top, bottomInset: insets.bottom)
    #expect(updated.count > old.count)
    #expect(updated.allSatisfy { $0.y >= 0 && $0.y + $0.height <= size.height * 0.85 })
  }

  @Test func continuousEmptyPlanDoesNotInsertLateTextHalfwayAcrossTheScreen() {
    let late = Danmaku(id: "late", time: 1, mode: 1, size: 25, color: 0xFFFFFF, text: "迟到的弹幕")
    let future = Danmaku(id: "future", time: 4, mode: 1, size: 25, color: 0xFFFFFF, text: "从边缘进入")
    let size = CGSize(width: 400, height: 200)
    let continuous = DanmakuLayout.prepare(items: [late, future], size: size,
      scale: 1, area: 1, duration: 8, time: 3, retaining: [])
    #expect(!continuous.contains { $0.item.id == late.id })
    #expect(continuous.contains { $0.item.id == future.id })
    // Starting or seeking to the same time must still reconstruct its frame.
    let seek = DanmakuLayout.prepare(items: [late, future], size: size,
      scale: 1, area: 1, duration: 8, time: 3)
    #expect(seek.contains { $0.item.id == late.id })
  }

  @Test func largerUpcomingFontCannotRemoveTextFromAnOldLowerLane() throws {
    let small = (0..<4).map {
      Danmaku(id: "small-\($0)", time: 1, mode: 1, size: 12, color: 0xFFFFFF, text: "正在滚动 \($0)")
    }
    let size = CGSize(width: 400, height: 190)
    let options = DanmakuDisplayOptions(avoidSubtitles: false)
    let first = DanmakuLayout.prepare(items: small, size: size, scale: 1,
      area: 1, duration: 8, time: 1, options: options)
    let lowest = try #require(first.last)
    #expect(lowest.lane == 3)
    let large = Danmaku(id: "large", time: 4, mode: 5, size: 36, color: 0xFFFFFF, text: "大字号")
    let updated = DanmakuLayout.prepare(items: small + [large], size: size, scale: 1,
      area: 1, duration: 8, time: 2, options: options, retaining: first)
    for original in first {
      let retained = try #require(updated.first { $0.item.id == original.item.id })
      #expect(retained.y == original.y)
      #expect(retained.width == original.width)
      #expect(retained.x(at: 2, viewportWidth: size.width) == original.x(at: 2, viewportWidth: size.width))
    }
    for added in updated where added.item.id == large.id {
      #expect(!first.contains { $0.y < added.y + added.height && added.y < $0.y + $0.height })
    }
  }

  @Test func runningTextSurvivesEvenWhenNewFontLeavesNoAvailableLanes() throws {
    let item = Danmaku(id: "small", time: 1, mode: 1, size: 12, color: 0xFFFFFF, text: "完整离开")
    let large = Danmaku(id: "large", time: 4, mode: 1, size: 36, color: 0xFFFFFF, text: "放不下")
    let size = CGSize(width: 400, height: 68)
    let options = DanmakuDisplayOptions(avoidSubtitles: false)
    let first = DanmakuLayout.prepare(items: [item], size: size, scale: 1,
      area: 1, duration: 8, time: 1, options: options)
    let original = try #require(first.first)
    let updated = DanmakuLayout.prepare(items: [item, large], size: size, scale: 1,
      area: 1, duration: 8, time: 8.9, options: options, retaining: first)
    let retained = try #require(updated.first { $0.item.id == item.id })
    #expect(retained.y == original.y)
    #expect(retained.x(at: 8.9, viewportWidth: size.width) + retained.width > 0)
    let finished = DanmakuLayout.prepare(items: [item, large], size: size, scale: 1,
      area: 1, duration: 8, time: 9, options: options, retaining: updated)
    #expect(!finished.contains { $0.item.id == item.id })
  }
}
