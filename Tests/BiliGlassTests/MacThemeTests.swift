import AppKit
import SwiftUI
import Testing
@testable import BiliGlass

@Suite(.serialized) @MainActor struct MacThemeTests {
  private struct SchemeProbe: View {
    @Environment(\.colorScheme) private var scheme
    let changed: (ColorScheme) -> Void
    var body: some View {
      Color.clear.frame(width: 240, height: 120)
        .onChange(of: scheme, initial: true) { changed(scheme) }
    }
  }

  @Test func liveThemeChangesAndReturningToSystemUpdateTheWindowContent() async throws {
    _ = NSApplication.shared
    let suite = "local.BiliGlass.ThemeTests." + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set("dark", forKey: "appearance")
    preferences.set("original", forKey: "appTheme")
    var displayed: ColorScheme?
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSHostingView(rootView: SchemeProbe { displayed = $0 }
      .appAppearance().defaultAppStorage(preferences))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let cases: [(String, ColorScheme)] = [
      ("original", .dark), ("light", .light), ("dark", .dark),
      ("system", SystemAppearance.shared.scheme), ("light", .light),
      ("original", .dark), ("system", SystemAppearance.shared.scheme),
    ]
    for (theme, expected) in cases {
      preferences.set(theme, forKey: "appTheme")
      for _ in 0..<100 where displayed != expected { try await Task.sleep(for: .milliseconds(5)) }
      #expect(displayed == expected, "Theme \(theme) did not update the hosted content")
      #expect(preferences.string(forKey: "appearance") == "dark")
    }
  }
}
