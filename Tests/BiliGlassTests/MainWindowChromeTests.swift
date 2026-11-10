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

  @Test func searchDismissesOutsideButNotWithinFieldOrPopup() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 760),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let content = try #require(window.contentView)
    let anchor = MainWindowChrome.WindowAnchor(frame: .zero)
    content.addSubview(anchor)
    anchor.searchActive = true
    anchor.searchRegions = [CGRect(x: 150, y: 8, width: 520, height: 28),
      CGRect(x: 150, y: 42, width: 520, height: 200)]
    var dismissals = 0
    anchor.dismissSearch = { dismissals += 1 }
    func click(_ point: NSPoint) throws {
      let location = NSPoint(x: point.x, y: content.bounds.height - point.y)
      let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: location,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
      #expect(!anchor.handleMouseDown(event))
    }
    try click(NSPoint(x: 200, y: 20))
    try click(NSPoint(x: 200, y: 100))
    #expect(dismissals == 0)
    try click(NSPoint(x: 800, y: 300))
    #expect(dismissals == 1)
  }
}
