import SwiftUI

/// Lets the search row share the title bar with AppKit's window controls.
struct MainWindowChrome: NSViewRepresentable {
  var toolbarControls: [CGRect] = []
  var searchRegions: [CGRect] = []
  var searchActive = false
  var dismissSearch: () -> Void = {}
  var windowInactive: () -> Void = {}
  func makeNSView(context: Context) -> WindowAnchor { WindowAnchor() }
  func updateNSView(_ view: WindowAnchor, context: Context) {
    view.toolbarControls = toolbarControls
    view.searchRegions = searchRegions
    view.searchActive = searchActive
    view.dismissSearch = dismissSearch
    view.windowInactive = windowInactive
    view.alignControls()
  }

  final class WindowAnchor: NSView {
    var toolbarControls: [CGRect] = []
    var searchRegions: [CGRect] = []
    var searchActive = false
    var dismissSearch: () -> Void = {}
    var windowInactive: () -> Void = {}
    private var resizeObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var mouseMonitor: Any?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
      if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
      if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
      resizeObserver = nil
      resignObserver = nil
      mouseMonitor = nil
      guard let window else { return }
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.titlebarSeparatorStyle = .none
      window.styleMask.insert(.fullSizeContentView)
      window.isMovableByWindowBackground = false
      resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
        object: window, queue: .main) { [weak self] _ in
          // AppKit resets the standard controls during resize. Reposition in
          // this layout turn so its default position cannot reach the screen.
          MainActor.assumeIsolated { self?.alignControls() }
        }
      resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
        object: window, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.windowInactive() }
        }
      mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
        let handled = MainActor.assumeIsolated { self?.handleMouseDown(event) ?? false }
        return handled ? nil : event
      }
      DispatchQueue.main.async { [weak self] in self?.alignControls() }
    }

    func handleMouseDown(_ event: NSEvent) -> Bool {
      guard let window, event.window === window, let content = window.contentView,
        window.attachedSheet == nil else { return false }
      let location = content.convert(event.locationInWindow, from: nil)
      let point = NSPoint(x: location.x, y: content.isFlipped ? location.y : content.bounds.height - location.y)
      if searchActive && !searchRegions.contains(where: { $0.contains(point) }) {
        dismissSearch()
        window.makeFirstResponder(nil)
      }
      guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control),
        !window.styleMask.contains(.fullScreen), point.y >= 0, point.y < AppLayout.mainHeaderHeight,
        point.x >= 80, point.x < content.bounds.width - 6,
        !toolbarControls.contains(where: { $0.contains(point) }) else { return false }
      if event.clickCount == 2 { window.performZoom(nil) }
      else if event.clickCount == 1 {
        // Leave the outer edge to AppKit's normal window-resize handling.
        guard point.y >= 6 else { return false }
        window.performDrag(with: event)
      }
      return true
    }

    func alignControls() {
      guard let window, !window.styleMask.contains(.fullScreen), let content = window.contentView else { return }
      for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
        guard let button = window.standardWindowButton(kind), let container = button.superview else { continue }
        let topCenter = AppLayout.mainToolbarTopInset + AppLayout.mainToolbarHeight / 2
        let centerY = content.isFlipped ? topCenter : content.bounds.maxY - topCenter
        let center = container.convert(NSPoint(x: 22 + CGFloat(index) * 20, y: centerY), from: content)
        button.setFrameOrigin(NSPoint(x: center.x - button.frame.width / 2, y: center.y - button.frame.height / 2))
      }
    }

    deinit {
      if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
      if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
      if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }
  }
}
