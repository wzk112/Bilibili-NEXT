import SwiftUI

private struct VideoTitleCopyAvailableKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
  var videoTitleCopyAvailable: Bool {
    get { self[VideoTitleCopyAvailableKey.self] }
    set { self[VideoTitleCopyAvailableKey.self] = newValue }
  }
}

extension View {
  func copyableVideoTitle(_ title: String) -> some View { modifier(CopyableVideoTitle(title: title)) }
}

private struct CopyableVideoTitle: ViewModifier {
  let title: String
  @Environment(\.videoTitleCopyAvailable) private var available
  @Environment(\.isEnabled) private var enabled
  func body(content: Content) -> some View {
    content.help(title)
      .background {
        TitleCopyRegion(title: title, enabled: available && enabled) {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(title, forType: .string)
        }
      }
  }
}

struct TitleCopyRegion: NSViewRepresentable {
  let title: String
  var enabled = true
  let copy: () -> Void
  func makeNSView(context: Context) -> CopyView { CopyView() }
  func updateNSView(_ view: CopyView, context: Context) {
    if view.title != title || !enabled { view.hideFeedback() }
    view.title = title; view.copyTitle = copy; view.enabled = enabled
  }
  final class CopyView: NSView {
    var enabled = true
    var title = ""
    var copyTitle: (() -> Void)?
    private var monitor: Any?
    private var feedback: NSPopover?
    private var feedbackTask: Task<Void, Never>?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      hideFeedback()
      if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
        let copied = MainActor.assumeIsolated { self?.handleSecondaryClick(event) ?? false }
        return copied ? nil : event
      }
    }
    func handleSecondaryClick(_ event: NSEvent) -> Bool {
      guard enabled, event.type == .rightMouseDown || event.modifierFlags.contains(.control),
        let window, event.window === window, window.attachedSheet == nil,
        !isHiddenOrHasHiddenAncestor else { return false }
      let point = convert(event.locationInWindow, from: nil)
      // AppKit may report a visibleRect larger than this background view when it
      // does not clip. Never let one card's monitor consume another card's click.
      guard bounds.contains(point), visibleRect.contains(point) else { return false }
      copyTitle?()
      showFeedback(for: event)
      return true
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func rightMouseDown(with event: NSEvent) { if enabled { copyTitle?(); showFeedback(for: event) } }
    override func mouseDown(with event: NSEvent) {
      if enabled, event.modifierFlags.contains(.control) { copyTitle?(); showFeedback(for: event) }
    }
    private func showFeedback(for event: NSEvent) {
      guard let window, window.isVisible else { return }
      hideFeedback()
      let point = convert(event.locationInWindow, from: nil)
      let popover = NSPopover()
      popover.behavior = .transient
      popover.animates = false
      popover.appearance = window.effectiveAppearance
      let size = NSSize(width: 112, height: 36)
      let controller = NSHostingController(rootView:
        HStack(spacing: 6) {
          Image(systemName: "checkmark")
          Text("已复制").lineLimit(1)
        }.font(.system(size: 12, weight: .medium)).fixedSize()
          .frame(width: size.width, height: size.height))
      controller.preferredContentSize = size
      popover.contentViewController = controller
      popover.contentSize = size
      // Anchor to the actual click, not the end of an overflowing title.
      feedback = popover
      feedbackTask = Task { [weak self] in
        guard let self, !Task.isCancelled, self.window === window, self.feedback === popover else { return }
        popover.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1),
          of: self, preferredEdge: .maxY)
        do { try await Task.sleep(for: .seconds(1.2)); self.hideFeedback() } catch { }
      }
    }
    func hideFeedback() {
      feedbackTask?.cancel(); feedbackTask = nil
      feedback?.close(); feedback = nil
    }
    isolated deinit {
      feedbackTask?.cancel(); feedback?.close()
      if let monitor { NSEvent.removeMonitor(monitor) }
    }
  }
}
