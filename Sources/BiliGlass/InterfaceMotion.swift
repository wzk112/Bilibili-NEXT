import SwiftUI

/// Shared timing for deliberate interface actions; playback progress and incoming lists stay immediate.
enum InterfaceMotion {
  static let navigation = Animation.spring(response: 0.40, dampingFraction: 0.84)
  static let press = Animation.spring(response: 0.24, dampingFraction: 0.72)
}

private struct InterfaceAnimation<Value: Equatable>: ViewModifier {
  let value: Value
  @AppStorage("interfaceAnimations") private var enabled = true
  @Environment(\.accessibilityReduceMotion) private var reduced
  func body(content: Content) -> some View {
    content.animation(enabled ? (reduced ? .easeOut(duration: 0.12) : InterfaceMotion.navigation) : nil, value: value)
  }
}

private struct InterfaceTransition: ViewModifier {
  var mini: Bool
  @AppStorage("interfaceAnimations") private var enabled = true
  @Environment(\.accessibilityReduceMotion) private var reduced
  func body(content: Content) -> some View {
    content.transition(!enabled || reduced ? .opacity : .opacity.combined(with:
      mini ? .scale(scale: 0.94, anchor: .bottomTrailing) : .offset(x: 24)))
  }
}

struct InterfacePressStyle: ButtonStyle {
  @AppStorage("interfaceAnimations") private var enabled = true
  @Environment(\.accessibilityReduceMotion) private var reduced
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && enabled && !reduced ? 0.975 : 1)
      .opacity(configuration.isPressed ? 0.78 : 1)
      .animation(enabled ? (reduced ? .easeOut(duration: 0.1) : InterfaceMotion.press) : nil, value: configuration.isPressed)
  }
}

extension View {
  func interfaceAnimation<V: Equatable>(_ value: V) -> some View { modifier(InterfaceAnimation(value: value)) }
  func interfaceTransition(mini: Bool = false) -> some View { modifier(InterfaceTransition(mini: mini)) }
}
