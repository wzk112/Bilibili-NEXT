import SwiftUI

@MainActor @Observable final class PlaybackSleepTimer {
  enum Mode: Equatable { case deadline(Date), endOfVideo }
  private(set) var mode: Mode?
  @ObservationIgnored var onExpire: (() -> Void)?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var token = UUID()

  func start(after seconds: TimeInterval) {
    guard seconds.isFinite, seconds > 0 else { return }
    cancel()
    mode = .deadline(Date().addingTimeInterval(seconds))
    let request = token
    task = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(seconds))
        guard let self, self.token == request else { return }
        self.expire()
      } catch { }
    }
  }
  func stopAtEnd() { cancel(); mode = .endOfVideo }
  func cancel() {
    task?.cancel(); task = nil
    mode = nil; token = UUID()
  }
  /// A countdown follows the playlist; the end-of-video option belongs to one episode.
  func videoChanged() { if mode == .endOfVideo { cancel() } }
  func consumeEnd() -> Bool {
    guard let mode else { return false }
    if case .deadline(let deadline) = mode, deadline > Date() { return false }
    expire()
    return true
  }
  func remaining(at date: Date) -> String {
    guard case .deadline(let deadline) = mode else { return "本集结束" }
    let seconds = Int(max(0, ceil(deadline.timeIntervalSince(date))))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
  private func expire() { cancel(); onExpire?() }
  isolated deinit { task?.cancel() }
}

struct PlaybackSleepMenu: View {
  let playback: Playback
  var body: some View {
    if case .deadline = playback.sleepTimer.mode {
      TimelineView(.periodic(from: .now, by: 1)) { context in menu(at: context.date) }
    } else { menu(at: .now) }
  }
  private func menu(at date: Date) -> some View {
    let timer = playback.sleepTimer
    return Menu {
      if timer.mode != nil {
        Text("将在\(timer.mode == .endOfVideo ? "本集结束后" : timer.remaining(at: date) + "后")暂停")
        Button("取消定时暂停") { timer.cancel() }
        Divider()
      }
      ForEach([15, 30, 60], id: \.self) { minutes in
        Button("\(minutes) 分钟后暂停") { timer.start(after: Double(minutes * 60)) }
      }
      Button { timer.stopAtEnd() } label: {
        if timer.mode == .endOfVideo { Label("本集结束后暂停", systemImage: "checkmark") }
        else { Text("本集结束后暂停") }
      }
    } label: {
      Label(timer.mode == nil ? "定时暂停" : timer.remaining(at: date),
        systemImage: timer.mode == nil ? "moon.zzz" : "moon.zzz.fill")
    }.help(timer.mode == nil ? "定时暂停" : "定时暂停 · " + timer.remaining(at: date))
      .accessibilityLabel(timer.mode == nil ? "定时暂停" : "定时暂停 · " + timer.remaining(at: date))
  }
}
