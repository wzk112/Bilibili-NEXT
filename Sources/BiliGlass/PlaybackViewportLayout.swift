import SwiftUI

/// Gives the video the space left by the actual title and controls. The
/// description starts below this viewport instead of competing with playback.
struct PlaybackViewportLayout: Layout {
  let viewportHeight: CGFloat
  private let spacing: CGFloat = 14

  private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
    guard subviews.count == 3 else { return [] }
    let proposal = ProposedViewSize(width: width, height: nil)
    let title = subviews[0].sizeThatFits(proposal)
    let controls = subviews[2].sizeThatFits(proposal)
    let available = max(180, viewportHeight - title.height - controls.height - spacing * 2)
    let videoHeight = min(width * 9 / 16, available)
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
    return CGSize(width: width, height: max(viewportHeight, frames.last?.maxY ?? 0))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
      view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading, proposal: ProposedViewSize(frame.size))
    }
  }
}
