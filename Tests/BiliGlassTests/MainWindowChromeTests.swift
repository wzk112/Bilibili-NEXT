import AppKit
import Testing
@testable import BiliGlass

@Suite(.serialized) @MainActor struct MainWindowChromeTests {
  @Test func resizingDoesNotAlternateWindowControlPositionsAcrossRunLoopTurns() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = try #require(window.contentView)
    let anchor = MainWindowChrome.WindowAnchor(frame: .zero)
    content.addSubview(anchor)
    try await Task.sleep(for: .milliseconds(20))
    let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    var centers = [[CGFloat]](repeating: [], count: kinds.count)
    func sample() throws {
      for (index, kind) in kinds.enumerated() {
        let button = try #require(window.standardWindowButton(kind))
        let rect = content.convert(button.bounds, from: button)
        centers[index].append(content.isFlipped ? rect.midY : content.bounds.maxY - rect.midY)
      }
    }
    for index in Array(0..<12) + Array((0..<12).reversed()) {
      window.setContentSize(NSSize(width: 1100 + index * 11, height: 760 + index * 7))
      content.superview?.layoutSubtreeIfNeeded()
      try sample()
      try await Task.sleep(for: .milliseconds(2))
      try sample()
    }
    let target = AppLayout.mainToolbarTopInset + AppLayout.mainToolbarHeight / 2
    for values in centers {
      let spread = (values.max() ?? 0) - (values.min() ?? 0)
      #expect(spread < 0.5, "Window control center range: \(values)")
      #expect(values.allSatisfy { abs($0 - target) < 0.5 })
    }
  }
}
