import SwiftUI

/// A single interpolated width moves both columns and their shared gutter.
struct SidePanelLayout: Layout {
  var panelWidth: CGFloat
  let spacing: CGFloat
  let edge: HorizontalEdge

  var animatableData: CGFloat {
    get { panelWidth }
    set { panelWidth = newValue }
  }

  private func widths(in width: CGFloat) -> (content: CGFloat, panel: CGFloat, gap: CGFloat) {
    let panel = min(max(0, panelWidth), max(0, width - spacing))
    let gap = spacing * min(1, panel / 52)
    return (max(0, width - panel - gap), panel, gap)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 2 else { return .zero }
    let width = proposal.width ?? (subviews[0].sizeThatFits(.unspecified).width + max(0, panelWidth) + spacing)
    let widths = widths(in: width)
    if let height = proposal.height { return CGSize(width: width, height: height) }
    let contentHeight = subviews[0].sizeThatFits(.init(width: widths.content, height: nil)).height
    let panelHeight = widths.panel > 0 ? subviews[1].sizeThatFits(.init(width: widths.panel, height: nil)).height : 0
    return CGSize(width: width, height: max(contentHeight, panelHeight))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else { return }
    let widths = widths(in: bounds.width)
    let contentX = edge == .leading ? widths.panel + widths.gap : 0
    let panelX = edge == .leading ? 0 : widths.content + widths.gap
    subviews[0].place(at: .init(x: bounds.minX + contentX, y: bounds.minY), anchor: .topLeading,
      proposal: .init(width: widths.content, height: proposal.height))
    subviews[1].place(at: .init(x: bounds.minX + panelX, y: bounds.minY), anchor: .topLeading,
      proposal: .init(width: widths.panel, height: proposal.height))
  }
}

/// Gives the video the space left by the actual title and controls. The
/// description starts below this viewport instead of competing with playback.
struct PlaybackViewportLayout: Layout {
  let viewportHeight: CGFloat
  private var widthExpansion: CGFloat
  private let spacing: CGFloat = 14

  init(viewportHeight: CGFloat, fillsWidth: Bool = false) {
    self.viewportHeight = viewportHeight
    self.widthExpansion = fillsWidth ? 1 : 0
  }

  var animatableData: CGFloat {
    get { widthExpansion }
    set { widthExpansion = newValue }
  }

  private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
    guard subviews.count == 3 else { return [] }
    let proposal = ProposedViewSize(width: width, height: nil)
    let title = subviews[0].sizeThatFits(proposal)
    let controls = subviews[2].sizeThatFits(proposal)
    let available = max(180, viewportHeight - title.height - controls.height - spacing * 2)
    let fullHeight = width * 9 / 16
    let fittedHeight = min(fullHeight, available)
    let videoHeight = fittedHeight + (fullHeight - fittedHeight) * min(1, max(0, widthExpansion))
    let videoWidth = videoHeight * 16 / 9
    return [
      CGRect(x: 0, y: 0, width: width, height: title.height),
      CGRect(x: (width - videoWidth) / 2, y: title.height + spacing,
        width: videoWidth, height: videoHeight),
      CGRect(x: 0, y: title.height + spacing * 2 + videoHeight,
        width: width, height: controls.height),
    ]
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = max(0, proposal.width ?? 0)
    let frames = frames(width: width, subviews: subviews)
    return CGSize(width: width, height: frames.last?.maxY ?? 0)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
      view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading, proposal: ProposedViewSize(frame.size))
    }
  }
}
