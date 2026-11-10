import SwiftUI

enum AppMetrics {
  static let pageInset: CGFloat = 16
  static let sectionSpacing: CGFloat = 16
  static let cardRadius: CGFloat = 16
  #if os(iOS)
  static let controlHeight: CGFloat = 44
  #else
  static let controlHeight: CGFloat = 32
  #endif
}

extension View {
  func moduleControl() -> some View { controlSize(.regular).frame(minHeight: AppMetrics.controlHeight) }
}

/// Keep Liquid Glass on current systems and use native materials on Sequoia.
struct AppGlass {
  var clearStyle = false
  var color: Color = .clear
  var isInteractive = false
  static let clear = AppGlass(clearStyle: true)
  static let regular = AppGlass()
  func tint(_ color: Color) -> Self { var copy = self; copy.color = color; return copy }
  func interactive(_ enabled: Bool = true) -> Self { var copy = self; copy.isInteractive = enabled; return copy }
}

extension View {
  @ViewBuilder func appGlassEffect<S: Shape>(_ glass: AppGlass = .regular, in shape: S) -> some View {
    if #available(macOS 26, iOS 26, *) {
      glassEffect((glass.clearStyle ? Glass.clear : Glass.regular).tint(glass.color).interactive(glass.isInteractive), in: shape)
    } else {
      background(.regularMaterial, in: shape)
        .background(glass.color, in: shape)
        .overlay(shape.strokeBorderCompat(.primary.opacity(0.12)))
    }
  }
}

private extension Shape {
  func strokeBorderCompat(_ color: Color) -> some View { stroke(color, lineWidth: 0.5).allowsHitTesting(false) }
}

struct AppGlassContainer<Content: View>: View {
  var spacing: CGFloat? = nil
  @ViewBuilder var content: () -> Content
  var body: some View {
    if #available(macOS 26, iOS 26, *) {
      GlassEffectContainer(spacing: spacing, content: content)
    } else { content() }
  }
}

struct AppMaterialButtonStyle: PrimitiveButtonStyle {
  var prominent = false
  func makeBody(configuration: Configuration) -> some View {
    if #available(macOS 26, iOS 26, *) {
      if prominent { button(configuration).buttonStyle(.glassProminent) }
      else { button(configuration).buttonStyle(.glass).tint(.primary) }
    } else {
      if prominent { button(configuration).buttonStyle(.borderedProminent) }
      else { button(configuration).buttonStyle(.bordered).tint(.primary) }
    }
  }
  private func button(_ configuration: Configuration) -> some View {
    Button(role: configuration.role, action: configuration.trigger) {
      configuration.label.frame(minHeight: AppMetrics.controlHeight - 14)
    }.controlSize(.regular)
  }
}

extension PrimitiveButtonStyle where Self == AppMaterialButtonStyle {
  static var appGlassButton: Self { .init() }
  static var appGlassProminent: Self { .init(prominent: true) }
}
