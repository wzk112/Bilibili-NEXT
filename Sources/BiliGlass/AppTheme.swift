import SwiftUI

/// Read the application's appearance, independent of a window's explicit override.
@MainActor @Observable final class SystemAppearance {
  static let shared = SystemAppearance()
  private(set) var scheme: ColorScheme
  @ObservationIgnored private var observation: NSKeyValueObservation?
  private init() {
    let app = NSApplication.shared
    scheme = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    observation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
      Task { @MainActor [weak self] in
        self?.scheme = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
      }
    }
  }
}

enum AppTheme: String, CaseIterable, Identifiable {
  case original, light, dark, system
  var id: String { rawValue }
  var title: String {
    switch self {
    case .original: "默认"
    case .light: "白色"
    case .dark: "暗色"
    case .system: "跟随系统"
    }
  }
  func preferredScheme(originalAppearance: String) -> ColorScheme? {
    switch self {
    case .original: originalAppearance == "system" ? nil : originalAppearance == "light" ? .light : .dark
    case .light: .light
    case .dark: .dark
    case .system: nil
    }
  }
  static func background(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(white: 0.075) : Color(white: 0.965)
  }
  static func surface(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(white: 0.115) : .white
  }
}

struct ThemePicker: View {
  @Binding var selection: AppTheme
  var body: some View {
    HStack(spacing: 12) {
      ForEach(AppTheme.allCases) { theme in
        Button { selection = theme } label: {
          VStack(spacing: 10) {
            ZStack {
              if theme == .original {
                LinearGradient(colors: [Color(red: 0.025, green: 0.05, blue: 0.09),
                  Color(red: 0.24, green: 0.22, blue: 0.33)], startPoint: .bottomLeading, endPoint: .topTrailing)
              } else if theme == .system {
                HStack(spacing: 0) { AppTheme.background(.light); AppTheme.background(.dark) }
              } else { AppTheme.background(theme == .light ? .light : .dark) }
              HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(.gray.opacity(0.3)).frame(width: 16)
                VStack(alignment: .leading, spacing: 5) {
                  Capsule().fill(biliPink).frame(width: 30, height: 5)
                  RoundedRectangle(cornerRadius: 3).fill(.gray.opacity(0.3))
                }
              }.padding(10)
            }.frame(height: 62).clipShape(.rect(cornerRadius: 8))
            HStack(spacing: 6) {
              Text(theme.title).font(.callout)
              Spacer(minLength: 0)
              Image(systemName: theme == selection ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(theme == selection ? biliPink : .secondary)
            }
          }.padding(10).frame(maxWidth: .infinity)
            .background(.primary.opacity(0.025), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
              theme == selection ? biliPink : .primary.opacity(0.12), lineWidth: theme == selection ? 2 : 1))
            .contentShape(.rect(cornerRadius: 12))
        }.buttonStyle(.plain).foregroundStyle(.primary)
          .accessibilityLabel(theme.title + "主题")
          .accessibilityAddTraits(theme == selection ? .isSelected : [])
      }
    }
  }
}

/// Reuses the maintainer's macOS 15 material fallback for the original theme.
struct ThemedMaterialSurface<S: Shape>: ViewModifier {
  let glass: AppGlass
  let shape: S
  @AppStorage("appTheme") private var theme = AppTheme.original
  @Environment(\.colorScheme) private var scheme
  func body(content: Content) -> some View {
    if theme == .original { content.platformGlassEffect(glass, in: shape) }
    else {
      content.background {
        shape.fill(AppTheme.surface(scheme)).overlay(shape.fill(glass.color))
      }.overlay(shape.stroke(.primary.opacity(0.07), lineWidth: 1).allowsHitTesting(false))
    }
  }
}
