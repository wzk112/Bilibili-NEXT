import Foundation
import Sparkle
import SwiftUI

struct ReleaseVersion: Comparable, Equatable {
  let components: [Int]
  init?(_ value: String) {
    let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
    let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
    guard (2...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
      parts.allSatisfy({ Int($0) != nil }) else { return nil }
    components = parts.map { Int($0)! }
  }
  static func < (lhs: Self, rhs: Self) -> Bool {
    for index in 0..<max(lhs.components.count, rhs.components.count) {
      let a = index < lhs.components.count ? lhs.components[index] : 0
      let b = index < rhs.components.count ? rhs.components[index] : 0
      if a != b { return a < b }
    }
    return false
  }
  static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

struct AppRelease: Decodable, Equatable {
  struct Asset: Decodable, Equatable {
    let name: String
    let browser_download_url: URL
  }
  let tag_name: String
  let html_url: URL
  let body: String?
  let draft: Bool
  let prerelease: Bool
  let assets: [Asset]

  func downloadURL(repository: String, architecture: String) -> URL? {
    assets.first { asset in
      (asset.name.hasSuffix("-macOS-\(architecture).zip") || asset.name.hasSuffix("-macOS-universal.zip"))
        && Self.trusted(asset.browser_download_url, repository: repository, releasesOnly: true)
    }?.browser_download_url
  }
  static func trusted(_ url: URL, repository: String, releasesOnly: Bool) -> Bool {
    guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
      url.port == nil else { return false }
    let base = "/" + repository + "/releases/"
    return url.path.hasPrefix(base + (releasesOnly ? "download/" : ""))
  }
}

@MainActor @Observable final class MacUpdater {
  static let shared = MacUpdater()
  let repository: String
  let currentVersion: String
  private(set) var checking = false
  private(set) var checked = false
  private(set) var release: AppRelease?
  private(set) var error: String?
  private(set) var lastChecked: Date?
  @ObservationIgnored private var controller: SPUStandardUpdaterController?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var presentCheckResult = false
  @ObservationIgnored private var started = false
  @ObservationIgnored private let session: URLSession
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let bundle: Bundle
  private(set) var automaticChecks: Bool
  private(set) var automaticInstallation: Bool
  var canInstallAutomatically: Bool { controller != nil }
  var hasNewVersion: Bool {
    guard let release, let remote = ReleaseVersion(release.tag_name), let current = ReleaseVersion(currentVersion) else { return false }
    return remote > current
  }
  var downloadURL: URL? {
    #if arch(arm64)
    release?.downloadURL(repository: repository, architecture: "arm64")
    #else
    release?.downloadURL(repository: repository, architecture: "x86_64")
    #endif
  }
  init(bundle: Bundle = .main, defaults: UserDefaults = .standard, session: URLSession? = nil) {
    self.bundle = bundle; self.defaults = defaults
    let candidate = bundle.object(forInfoDictionaryKey: "BiliUpdateRepository") as? String ?? "wzk112/Bilibili-NEXT"
    repository = Self.validRepository(candidate) ? candidate : "wzk112/Bilibili-NEXT"
    currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? GuideContent.version
    automaticChecks = defaults.object(forKey: "automaticUpdateChecks") as? Bool ?? true
    automaticInstallation = defaults.bool(forKey: "automaticUpdateInstallation")
    lastChecked = defaults.object(forKey: "lastUpdateCheck") as? Date
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = 25
    self.session = session ?? URLSession(configuration: configuration)
  }
  static func validRepository(_ raw: String) -> Bool {
    let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." &&
      $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) } }
  }
  func start() {
    // Preview/test bundles must never replace themselves with a production release.
    guard bundle.bundleURL.pathExtension == "app", bundle.bundleIdentifier == "local.BiliGlass" else { return }
    guard !started else { return }; started = true
    if let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
      Data(base64Encoded: key)?.count == 32,
      let rawFeed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      let feed = URL(string: rawFeed), feed.scheme == "https", feed.host != nil, feed.user == nil {
      let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
      self.controller = controller
      controller.updater.automaticallyChecksForUpdates = automaticChecks
      controller.updater.automaticallyDownloadsUpdates = automaticInstallation
      controller.startUpdater()
    } else if automaticChecks, lastChecked.map({ Date().timeIntervalSince($0) >= 86_400 }) ?? true {
      check()
    }
  }
  func setAutomaticChecks(_ value: Bool) {
    automaticChecks = value; defaults.set(value, forKey: "automaticUpdateChecks")
    controller?.updater.automaticallyChecksForUpdates = value
    if !value { setAutomaticInstallation(false) }
  }
  func setAutomaticInstallation(_ value: Bool) {
    let enabled = value && canInstallAutomatically && automaticChecks
    automaticInstallation = enabled; defaults.set(enabled, forKey: "automaticUpdateInstallation")
    controller?.updater.automaticallyDownloadsUpdates = enabled
  }
  func install() { controller?.checkForUpdates(nil) }
  func check(presentResult: Bool = false) {
    presentCheckResult = presentCheckResult || presentResult
    guard !checking else { return }
    checking = true; error = nil
    task = Task { [weak self] in
      guard let self else { return }
      defer {
        checking = false; task = nil
        if presentCheckResult { presentCheckResult = false; showResult() }
      }
      do {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bilibili-NEXT-Update-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
          let status = (response as? HTTPURLResponse)?.statusCode ?? 0
          throw BiliError(text: status == 404 ? "发布源暂无可用版本" : status == 403 || status == 429 ? "检查更新过于频繁，请稍后重试" : "检查更新失败（\(status)）")
        }
        let result = try JSONDecoder().decode(AppRelease.self, from: data)
        guard !result.draft, !result.prerelease, ReleaseVersion(result.tag_name) != nil,
          AppRelease.trusted(result.html_url, repository: repository, releasesOnly: false) else {
          throw BiliError(text: "更新信息无效，请稍后重试")
        }
        release = result; checked = true; lastChecked = .now
        defaults.set(lastChecked, forKey: "lastUpdateCheck")
      } catch is CancellationError { }
      catch { self.error = error.localizedDescription }
    }
  }
  private func showResult() {
    let alert = NSAlert()
    alert.messageText = error != nil ? "暂时无法检查更新" : hasNewVersion ? "发现新版本 \(release?.tag_name ?? "")" : "当前已是最新版本"
    alert.informativeText = error ?? (hasNewVersion ? "可以查看更新说明并更新应用。" : "当前版本：\(currentVersion)")
    if hasNewVersion && error == nil {
      alert.addButton(withTitle: canInstallAutomatically ? "下载并安装…" : downloadURL != nil ? "下载 Mac 新版" : "查看发布说明")
      alert.addButton(withTitle: "稍后")
    } else { alert.addButton(withTitle: "好") }
    let action: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self, response == .alertFirstButtonReturn, self.error == nil, self.hasNewVersion else { return }
      if self.canInstallAutomatically { self.install() }
      else if let url = self.downloadURL ?? self.release?.html_url { NSWorkspace.shared.open(url) }
    }
    if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: action) }
    else { action(alert.runModal()) }
  }
  isolated deinit { task?.cancel() }
}

struct UpdatePreferences: View {
  private var updater = MacUpdater.shared
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        if updater.checking { ProgressView().controlSize(.small); Text("正在检查更新…") }
        else if updater.hasNewVersion { Label("发现新版本 \(updater.release?.tag_name ?? "")", systemImage: "arrow.down.circle") }
        else { Text(updater.checked ? "当前已是最新版本" : "检查是否有新版本") }
        Spacer()
        Button("检查更新") { updater.check() }.disabled(updater.checking)
      }
      if updater.hasNewVersion, let release = updater.release {
        if let notes = release.body, !notes.isEmpty {
          ScrollView { Text(notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(maxHeight: 160)
        }
        HStack(spacing: 20) {
          if updater.canInstallAutomatically { Button("下载并安装…") { updater.install() } }
          else if let url = updater.downloadURL { Link("下载 Mac 新版", destination: url) }
          Link("查看发布说明", destination: release.html_url)
        }
      }
      Toggle("自动检查新版本", isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks))
      Toggle("自动下载并安装更新", isOn: Binding(get: { updater.automaticInstallation }, set: updater.setAutomaticInstallation))
        .disabled(!updater.canInstallAutomatically || !updater.automaticChecks)
      if !updater.canInstallAutomatically {
        Text("此构建支持检查和下载新版；自动安装需要发行版提供签名更新源。")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let last = updater.lastChecked { Text("上次检查：" + last.formatted(AppDateFormat.timestamp)).font(.caption).foregroundStyle(.secondary) }
      if let error = updater.error { Text(error).font(.callout).foregroundStyle(.secondary) }
    }.buttonStyle(.glass).toggleStyle(.switch).tint(biliPink)
  }
}
