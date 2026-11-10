import AppKit
import SwiftUI
import Testing
@testable import BiliGlass

@Suite(.serialized) @MainActor struct MacHomeNavigationTests {
  private func preferences(order: String = "", hidden: String = "", start: String = "recommend") -> BrowsePreferences {
    .init(recommended: true, popular: true, start: start, hidden: hidden, order: order)
  }
  @Test func oldPersonalEntriesDoNotDisruptContentOrderingOrRemoveLiveCatalogs() {
    let original = preferences(order: "history,popular,favorites,recommend,messages,live,profile,cinema,bangumi,dynamic,regions")
    #expect(original.sidebarPages == [.popular, .recommend, .live, .cinema, .bangumi, .dynamic, .regions])
    var changed = original
    changed.order = original.movingSidebarPage(.recommend, by: -1)
    #expect(changed.sidebarPages == [.recommend, .popular, .live, .cinema, .bangumi, .dynamic, .regions])
    for index in original.order.indices where !original.order[index].isSidebarPage {
      #expect(changed.order[index] == original.order[index])
    }
    changed.order = changed.movingSidebarPage(.recommend, by: -1)
    #expect(changed.sidebarPages.first == .recommend)
    #expect(preferences(hidden: "live,popular").sidebarPages.allSatisfy { $0 != .live && $0 != .popular })
  }
  @Test func removedMoreStartupUsesSafeFallbackAndAllHiddenKeepsPersonalCenter() {
    #expect(preferences(start: "web").resolvedStart == .history)
    #expect(!preferences().visible.contains(.web))
    #expect(preferences(hidden: StartPage.allCases.map(\.rawValue).joined(separator: ",")).resolvedStart == .profile)
  }


  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

  @Test func realSettingsControlPersistsBothSidebarCollapseModes() async throws {
    _ = NSApplication.shared
    let suite = "local.BiliGlass.SidebarSettingsTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 900),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = NSHostingView(rootView: BrowsePreferenceFields().defaultAppStorage(defaults))
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(30))
    let picker = try #require(descendants(view).compactMap { $0 as? NSSegmentedControl }.first)
    #expect(picker.segmentCount == 2 && picker.selectedSegment == 0)
    let action = try #require(picker.action)
    for (segment, rawValue) in [(1, "hidden"), (0, "icons")] {
      picker.selectedSegment = segment
      #expect(picker.sendAction(action, to: picker.target))
      for _ in 0..<100 where defaults.string(forKey: "macSidebarCollapseMode") != rawValue {
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(defaults.string(forKey: "macSidebarCollapseMode") == rawValue)
    }
  }
}
