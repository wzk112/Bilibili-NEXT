import SwiftUI

/// Keep the system's button rendering while defining a pointer only over the
/// interactive control. AppKit continues to own text and window resize cursors.
struct InteractiveButtonStyle: PrimitiveButtonStyle {
  enum Kind { case glass, prominent, plain }
  let kind: Kind
  @ViewBuilder func makeBody(configuration: Configuration) -> some View {
    switch kind {
    case .glass: Button(configuration).buttonStyle(.appGlassButton).interactivePointer()
    case .prominent: Button(configuration).buttonStyle(.appGlassProminent).interactivePointer()
    case .plain: Button(configuration).buttonStyle(.plain).interactivePointer()
    }
  }
}

extension PrimitiveButtonStyle where Self == InteractiveButtonStyle {
  static var pointerGlass: Self { Self(kind: .glass) }
  static var pointerGlassProminent: Self { Self(kind: .prominent) }
  static var pointerPlain: Self { Self(kind: .plain) }
}
