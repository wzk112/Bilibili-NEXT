import SwiftUI

/// Shared timing for deliberate interface actions; playback progress and incoming lists stay immediate.
enum InterfaceMotion {
  static let navigation = Animation.spring(response: 0.40, dampingFraction: 0.84)
  static let press = Animation.spring(response: 0.24, dampingFraction: 0.72)
}

private struct InterfaceAnimation<Value: Equatable>: ViewModifier {
  let value: Value
  let animation: Animation
  @AppStorage("interfaceAnimations") private var enabled = true
  @Environment(\.accessibilityReduceMotion) private var reduced
  func body(content: Content) -> some View {
    content.animation(enabled ? (reduced ? .easeOut(duration: 0.12) : animation) : nil, value: value)
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
      .interactivePointer()
  }
}

extension View {
  @ViewBuilder func interactivePointer() -> some View {
    #if os(macOS)
    modifier(InteractivePointer())
    #else
    self
    #endif
  }
  func interfaceAnimation<V: Equatable>(_ value: V, animation: Animation = InterfaceMotion.navigation) -> some View {
    modifier(InterfaceAnimation(value: value, animation: animation))
  }
  func interfaceTransition(mini: Bool = false) -> some View { modifier(InterfaceTransition(mini: mini)) }
  func interfaceFade<V: Equatable>(_ trigger: V) -> some View { modifier(InterfaceFade(trigger: trigger)) }
}

/// Animate the current view's opacity without keeping an outgoing layout alive.
private struct InterfaceFade<Trigger: Equatable>: ViewModifier {
  let trigger: Trigger
  @AppStorage("interfaceAnimations") private var enabled = true
  @Environment(\.accessibilityReduceMotion) private var reduced

  @ViewBuilder func body(content: Content) -> some View {
    if enabled && !reduced {
      content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, opacity in
        view.opacity(opacity)
      } keyframes: { _ in
        MoveKeyframe(0.68)
        CubicKeyframe(1, duration: 0.17)
      }
    } else { content }
  }
}

#if os(macOS)
private struct InteractivePointer: ViewModifier {
  @Environment(\.isEnabled) private var enabled
  func body(content: Content) -> some View {
    content.pointerStyle(enabled ? .link : .default)
  }
}
#endif
