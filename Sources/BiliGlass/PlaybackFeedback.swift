import AppKit
import SwiftUI

@MainActor @Observable final class PlaybackFeedback {
  struct Notice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let symbol: String
  }
  private(set) var notice: Notice?
  @ObservationIgnored private var dismissal: Task<Void, Never>?

  func show(_ title: String, symbol: String, duration: Duration = .milliseconds(1200)) {
    dismissal?.cancel()
    let current = Notice(title: title, symbol: symbol)
    notice = current
    dismissal = Task { [weak self] in
      do {
        try await Task.sleep(for: duration)
        guard let self, self.notice?.id == current.id else { return }
        self.notice = nil
        self.dismissal = nil
      } catch { }
    }
  }

  func clear() {
    dismissal?.cancel(); dismissal = nil
    notice = nil
  }
  isolated deinit { dismissal?.cancel() }
}

struct PlaybackFeedbackOverlay: View {
  let feedback: PlaybackFeedback
  @AppStorage("interfaceAnimations") private var animations = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @State private var lastAnnouncement: ContinuousClock.Instant?
  var body: some View {
    ZStack {
      if let notice = feedback.notice {
        Label(notice.title, systemImage: notice.symbol)
          .font(.callout.weight(.medium)).monospacedDigit()
          .padding(.horizontal, 18).padding(.vertical, 12)
          .glassEffect(.regular, in: .capsule)
          .id(notice.id).transition(.opacity)
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
      .environment(\.colorScheme, .dark).foregroundStyle(.primary)
      .allowsHitTesting(false).accessibilityHidden(true)
      .animation(animations && !reduceMotion ? .easeOut(duration: 0.12) : nil, value: feedback.notice?.id)
      .onChange(of: feedback.notice?.id) {
        guard voiceOver, let notice = feedback.notice else { return }
        if let lastAnnouncement, lastAnnouncement.duration(to: .now) < .milliseconds(350) { return }
        lastAnnouncement = .now
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
          userInfo: [.announcement: notice.title, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
      }
  }
}
