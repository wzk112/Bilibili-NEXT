import Sparkle
import SwiftUI

@MainActor @Observable final class AppUpdater {
  static let shared = AppUpdater()
  private(set) var ready = false
  private(set) var canCheck = false
  private(set) var automaticChecks = false
  private(set) var automaticDownloads = false
  private(set) var lastChecked: Date?
  private(set) var error: String?
  @ObservationIgnored private var controller: SPUStandardUpdaterController?
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []

  func start() {
    guard controller == nil, Bundle.main.bundleURL.pathExtension == "app",
      Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
    let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    self.controller = controller
    do {
      try controller.updater.start()
      ready = true
      let updater = controller.updater
      observations = [
        updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in self?.refresh() },
        updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in self?.refresh() },
        updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in self?.refresh() },
        updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in self?.refresh() },
      ]
      updateState()
    } catch { self.error = error.localizedDescription }
  }
  nonisolated private func refresh() {
    Task { @MainActor [weak self] in self?.updateState() }
  }
  private func updateState() {
    guard let updater = controller?.updater else { return }
    canCheck = updater.canCheckForUpdates
    automaticChecks = updater.automaticallyChecksForUpdates
    automaticDownloads = updater.automaticallyDownloadsUpdates
    lastChecked = updater.lastUpdateCheckDate
  }
  func check() { controller?.checkForUpdates(nil) }
  func setAutomaticChecks(_ enabled: Bool) {
    controller?.updater.automaticallyChecksForUpdates = enabled
    updateState()
  }
  func setAutomaticDownloads(_ enabled: Bool) {
    controller?.updater.automaticallyDownloadsUpdates = enabled
    updateState()
  }
}

struct UpdateSettings: View {
  private var updater: AppUpdater { .shared }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button("检查更新…") { updater.check() }.disabled(!updater.canCheck)
        .accessibilityIdentifier("check-for-updates")
      Toggle("自动检查更新", isOn: Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) }))
        .disabled(!updater.ready)
      Toggle("自动下载并在退出时安装更新", isOn: Binding(get: { updater.automaticDownloads }, set: { updater.setAutomaticDownloads($0) }))
        .disabled(!updater.ready || !updater.automaticChecks)
      if let date = updater.lastChecked {
        Text("上次检查：" + date.formatted(AppDateFormat.timestamp)).font(.caption).foregroundStyle(.secondary)
      }
      if let error = updater.error { Text(error).font(.caption).foregroundStyle(.secondary) }
      Link("查看发布页面", destination: URL(string: "https://github.com/wzk112/Bilibili-NEXT/releases/latest")!)
    }.task { updater.start() }
  }
}
