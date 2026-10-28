import AVKit
import MediaPlayer
import CoreImage.CIFilterBuiltins
import SwiftUI
import WebKit

typealias MobileDanmaku = DanmakuController

/// Session setup can wait for audio routing; keep it off the interface executor.
private actor MobileAudioSession {
  static let shared = MobileAudioSession()
  func activate() async throws {
    let audio = AVAudioSession.sharedInstance()
    try audio.setCategory(.playback, mode: .moviePlayback)
    if #available(iOS 27, *) {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        audio.activate(options: []) { active, error in
          if let error {
            continuation.resume(throwing: error)
          } else if active {
            continuation.resume()
          } else {
            continuation.resume(throwing: BiliError(text: "音频输出未能激活"))
          }
        }
      }
    } else {
      try audio.setActive(true)
    }
  }
}

struct HistoryEntry: Codable, Identifiable {
  var id: String { "\(accountID ?? "legacy"):\(video.bvid)" }
  var video: Video
  var positions: [String: Double]
  var date: Date
  var lastCID: Int?
  var accountID: String?
}
struct WebTarget: Identifiable {
  let id = UUID()
  let url: URL
  let title: String
}
@MainActor @Observable final class Store {
  let api: API
  let playback = Playback()
  let mobilePiP = MobilePiPSession()
  let downloads = Downloads()
  let extras = VideoExtras()
  var comments = Comments()
  let playerNavigation = MobilePlayerNavigation()
  let actions = VideoActionsModel()
  let inbox = InboxModel()
  let messageUnread = MessageUnreadModel()
  let accountHistory = AccountHistory()
  let historySync = WatchHistorySync()
  let danmaku = MobileDanmaku()
  var account: Account?
  var credentialsRestored = false
  var restoring = true
  var accountRestoreMessage: String?
  var accountNeedsRetry = false
  private var checkingAccount = false
  private var started = false
  var specialScripts = 0
  var specialLayers = 0
  var unsupportedScripts = 0
  var favoriteRevision = 0
  var danmakuPerformance: [String: Double] = [:]
  var orientationDiagnostics: [String: String] = [:]
  var homeFeeds = MobileHomeFeeds()
  var homeReturnRevision = 0
  var browseDestination = BrowsePreferences().resolvedStart
  var homeRegion = 1005
  var phoneHomeTab = BrowsePreferences().resolvedStart == .popular ? 1 : BrowsePreferences().resolvedStart == .regions ? 2 : 0
  var isRecommendedVisible = BrowsePreferences().resolvedStart == .recommend
  var showPlayer = false {
    didSet { if oldValue && !showPlayer { homeReturnRevision += 1 } }
  }
  var conversationPresented = false
  var isPlaybackOpen = false
  var showLogin = false
  var webTarget: WebTarget?
  var message: String?
  var qrImage: CGImage?
  var loginStatus = ""
  var loginExpired = false
  var loginCompletion = UUID()
  var history: [HistoryEntry] = []
  var queue: [PlaybackQueueItem] = []
  private var loginTask: Task<Void, Never>?
  private var loginCode: String?
  private var loginDeadline = Date.distantPast
  private var loginGeneration = UUID()
  private var loginPaused = false
  private var qaTask: Task<Void, Never>?
  private var qaTransferSamples: [[String: Any]] = []
  private var audioTask: Task<Void, Never>?
  private var audioNotifications: [NSObjectProtocol] = []
  var nowPlaying: MobileNowPlaying?
  private var resumeAfterInterruption = false
  var lastAudioEvent = "none"
  init() {
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    #if DEBUG
      api =
        MobileUIFixture.sessionRestorationEnabled ? MobileUIFixture.makeSessionAPI() : MobileFavoriteFixture.enabled
        ? MobileFavoriteFixture.makeAPI()
        : MobileUIFixture.enabled ? MobileUIFixture.makeAPI() : API(loadCredentials: false)
    #else
      api = API(loadCredentials: false)
    #endif
    UserDefaults.standard.register(defaults: [
      "appearance": "system", "videoThreads": 4, "continuousPreload": true,
      "bufferSeconds": 15.0, "rememberPosition": true, "syncWatchHistory": true, "autoPlay": true,
      "videoCodecPreference": "hevc", "downloadThreads": 4, "simultaneousDownloads": 1,
      "danmakuEnabled": true,
    ])
    if let data = UserDefaults.standard.data(forKey: "history") {
      history = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }
    inbox.onRead = { [weak self] in
      guard let self else { return }; await self.messageUnread.refresh(api: self.api)
    }
    playback.onProgress = { [weak self] bvid, cid, seconds, final in
      self?.save(bvid, cid: cid, seconds: seconds, final: final)
    }
    playback.onEnded = { [weak self] in
      guard let self else { return }
      if UserDefaults.standard.bool(forKey: "loopVideo") {
        self.playback.seek(to: 0)
        self.playback.player.playImmediately(atRate: self.playback.speed)
      } else if let item = PlaybackSequence.next(detail: self.playback.detail, cid: self.playback.selectedCID,
        queue: self.queue, parts: (UserDefaults.standard.object(forKey: "autoPlayParts") == nil || UserDefaults.standard.bool(forKey: "autoPlayParts")),
        collection: UserDefaults.standard.bool(forKey: "autoPlayNext")) {
        self.advance(to: item)
      }
    }
    audioNotifications.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        Task { @MainActor in
          guard let self else { return }
          self.lastAudioEvent = "interruption-\(type ?? 99)-options-\(options)"
          self.playback.endTemporarySpeed()
          if type == AVAudioSession.InterruptionType.began.rawValue {
            self.resumeAfterInterruption = self.playback.pendingResume?.playing ?? (self.playback.player.rate != 0)
            self.playback.pausePlayback()
          } else {
            let resume = self.resumeAfterInterruption
            self.resumeAfterInterruption = false
            if resume && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
              && (UIApplication.shared.applicationState != .background || self.backgroundPlaybackEnabled) {
              self.resumePlayback()
            }
          }
        }
      })
    audioNotifications.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] note in
        let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
          Task { @MainActor in
            self?.lastAudioEvent = "route-old-device-unavailable"
            self?.resumeAfterInterruption = false
            self?.playback.pausePlayback()
          }
        }
      })
    updateBackgroundPlayback()
    nowPlaying = MobileNowPlaying(store: self)
  }
  func start() async {
    guard !started else { return }
    started = true
    #if DEBUG
      if MobileUIFixture.enabled {
        account = Account(name: "本地测试", mid: 1, face: "")
        credentialsRestored = true
        restoring = false
        if ProcessInfo.processInfo.arguments.contains("--qa-navigation") { open("BV1xx411c7mD") }
        if ProcessInfo.processInfo.arguments.contains("--qa-capture") {
          qaTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            MobileUIFixture.captureInterface()
          }
        }
        return
      }
      if MobileFavoriteFixture.enabled {
        account = Account(name: "本地测试", mid: 1, face: "")
        credentialsRestored = true
        restoring = false
        let detail = Detail(
          video: Video(
            bvid: "BV1xx411c7mD", title: "收藏保存测试", cover: "",
            author: "本地测试", duration: 0, views: 0), description: "", pages: [], aid: 123)
        playback.detail = detail
        await actions.load(detail: detail, accountID: 1, api: api)
        showPlayer = true
        return
      }
    #endif
    PlaybackTemporaryFiles.cleanup()
    await api.restoreCredentials()
    guard !Task.isCancelled else { started = false; return }
    account = LoginRestoration.localAccount(api: api, previous: account)
    credentialsRestored = true
    await refreshAccount()
    restoring = false
    let args = ProcessInfo.processInfo.arguments
    var qa = args.contains("--qa-capture") && !args.contains("--qa-video")
    #if DEBUG
      if let i = args.firstIndex(of: "--qa-connections"), args.indices.contains(i + 1), let count = Int(args[i + 1]) { playback.connectionOverride = max(1, min(32, count)) }
      if let i = args.firstIndex(of: "--qa-fixture"), args.indices.contains(i + 1),
        args[i + 1] == (args[i + 1] as NSString).lastPathComponent
      {
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("QA").appendingPathComponent(args[i + 1])
        if FileManager.default.fileExists(atPath: file.path) {
          activateAudio()
          isPlaybackOpen = true
          showPlayer = true
          playback.openLocal(
            file,
            video: Video(
              bvid: "QA-local", title: "本地手势测试",
              cover: "", author: "", duration: 90, views: 0))
          if args.contains("--qa-special"),
            let data = try? Data(
              contentsOf: file.deletingLastPathComponent().appendingPathComponent("special.json")),
            data.count <= 2_000_000,
            let items = try? JSONDecoder().decode([Danmaku].self, from: data)
          {
            danmaku.items = items
          }
          qa = true
        }
      }
    #endif
    if !qa, let i = args.firstIndex(of: "--qa-video"), args.indices.contains(i + 1),
      let bvid = videoID(args[i + 1])
    {
      #if DEBUG
        if args.contains("--qa-quality-cycle") { playback.persistQualityPreference = false }
      #endif
      if args.contains("--qa-from-start") {
        let visit = MobileVideoVisit(bvid: bvid)
        visit.resume = PlaybackResume(position: 0, playing: true)
        beginVisit(visit)
      } else { open(bvid) }
      qa = true
    }
    if qa {
      qaTask = Task { [weak self] in
        for sample in 0..<90 {
          try? await Task.sleep(for: .seconds(1))
          guard let self, !Task.isCancelled else { return }
          await self.writeQA()
          #if DEBUG
            if args.contains("--qa-sequence-check") && sample == 20 && !self.playback.loading && self.playback.durationSeconds > 5 {
              await self.writeQA(suffix: "-before-next")
              self.playback.seek(to: self.playback.durationSeconds - 2)
            }
            // Explicit device regression mode; avoids an additional test-runner
            // app on devices already at the free-signing installation limit.
            if args.contains("--qa-quality-cycle") {
              if sample == 6, args.contains("--qa-4k"), self.playback.durationSeconds > 60, !self.playback.loading {
                await self.playback.player.seek(to: CMTime(seconds: self.playback.durationSeconds * 0.55,
                  preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
              } else if sample == 12 {
                await self.writeQA(suffix: "-initial")
                self.playback.selectQuality(args.contains("--qa-4k") ? 120 : 64, api: self.api)
              } else if sample == 28 {
                await self.writeQA(suffix: args.contains("--qa-4k") ? "-4k-first" : "-720p")
                self.playback.player.pause()
                self.playback.selectQuality(80, api: self.api)
              } else if sample == 44 {
                await self.writeQA(suffix: "-1080p-paused")
                MobileUIFixture.captureInterface()
                if args.contains("--qa-4k") {
                  self.playback.togglePlayback()
                  self.playback.selectQuality(120, api: self.api)
                }
              } else if sample == 65, args.contains("--qa-4k") {
                await self.writeQA(suffix: "-4k-final")
                MobileUIFixture.captureInterface()
              }
            }
            if args.contains("--qa-capture") && sample == 20 { MobileUIFixture.captureInterface() }
          #endif
        }
      }
    }
  }
  func open(_ bvid: String, initialCID: Int? = nil) {
    if showPlayer, let current = playerNavigation.current,
      current.bvid == bvid, initialCID == nil || initialCID == playback.selectedCID
    {
      // A repeated link returns to the existing video instead of adding a duplicate visit.
      if let index = playerNavigation.path.lastIndex(of: .video(current.id)) {
        playerNavigation.path = Array(playerNavigation.path.prefix(index + 1))
      } else {
        playerNavigation.path = []
      }
      return
    }
    beginVisit(MobileVideoVisit(bvid: bvid, cid: initialCID))
  }
  private func captureVisit() {
    guard let visit = playerNavigation.current else { return }
    visit.detail = playback.detail
    visit.cid = playback.selectedCID > 0 ? playback.selectedCID : visit.cid
    visit.resume =
      playback.pendingResume
      ?? PlaybackResume(position: playback.positionSeconds, playing: playback.isPlaying)
    visit.queue = queue
    playback.saveCurrentProgress()
  }
  private func beginVisit(_ visit: MobileVideoVisit) {
    captureVisit()
    let nested = showPlayer && playerNavigation.root != nil
    if !nested { playerNavigation.reset() }
    playerNavigation.visits[visit.id] = visit
    playerNavigation.active = visit.id
    if nested {
      playerNavigation.path.append(.video(visit.id))
    } else {
      playerNavigation.root = visit
    }
    queue = visit.queue
    loadVisit(visit)
    showPlayer = true
  }
  func restorePlayerRoute() {
    guard let visit = playerNavigation.visibleVideo else { return }
    if playerNavigation.active != visit.id {
      captureVisit()
      playerNavigation.active = visit.id
      queue = visit.queue
      loadVisit(visit)
    }
    playerNavigation.prune()
  }
  private func loadVisit(_ visit: MobileVideoVisit) {
    isPlaybackOpen = true
    comments = visit.comments
    extras.reset()
    danmaku.stop()
    actions.clear()
    activateAudio()
    #if DEBUG
      if MobileUIFixture.enabled {
        MobileUIFixture.openVideo(visit, store: self)
        return
      }
    #endif
    if let local = visit.local {
      playback.openLocal(
        URL(fileURLWithPath: local.path), video: local.video, cid: local.cid,
        sidecar: local.danmakuPath.map { URL(fileURLWithPath: $0) }, restoring: visit.resume)
    } else {
      var diagnosticQuality: Int?
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--qa-4k") { diagnosticQuality = 80 }
      #endif
      playback.open(visit.bvid, api: api, quality: diagnosticQuality, initialCID: visit.cid, restoring: visit.resume) {
        [weak self] cid in
        self?.position(visit.bvid, cid: cid) ?? 0
      }
    }
  }
  func resumePlayback() {
    audioTask?.cancel()
    audioTask = Task { [weak self] in
      do {
        try await MobileAudioSession.shared.activate()
        try Task.checkCancellation()
        guard let self, self.isPlaybackOpen else { return }
        self.playback.continuePlayback()
        self.nowPlaying?.update()
      } catch { if !Task.isCancelled { self?.message = "音频会话：" + error.localizedDescription } }
    }
  }
  private func activateAudio() {
    audioTask?.cancel()
    audioTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        try await MobileAudioSession.shared.activate()
      } catch {
        if !Task.isCancelled { self?.message = "音频会话：" + error.localizedDescription }
      }
    }
  }
  func position(_ bvid: String, cid: Int) -> Double {
    guard UserDefaults.standard.bool(forKey: "rememberPosition") else { return 0 }
    return history.first { $0.video.bvid == bvid && $0.accountID == owner }?.positions[String(cid)]
      ?? 0
  }
  var owner: String { api.cookies["DedeUserID"] ?? "guest" }
  func save(_ bvid: String, cid: Int, seconds: Double, final: Bool) {
    guard seconds.isFinite, seconds >= 0, let detail = playback.detail, detail.video.bvid == bvid
    else { return }
    var row =
      history.first { $0.video.bvid == bvid && $0.accountID == owner }
      ?? HistoryEntry(video: detail.video, positions: [:], date: .now, accountID: owner)
    row.positions[String(cid)] = seconds
    row.lastCID = cid
    row.date = .now
    history.removeAll { $0.id == row.id }
    history.insert(row, at: 0)
    history = Array(history.prefix(500))
    persist()
    historySync.record(
      api: api, aid: detail.aid, bvid: bvid, cid: cid, seconds: seconds, final: final)
  }
  func persist() {
    downloads.persist()
    if let data = try? JSONEncoder().encode(history) {
      UserDefaults.standard.set(data, forKey: "history")
    }
  }
  var currentQueue: [PlaybackQueueItem] {
    let parts = PlaybackSequence.parts(playback.detail)
    if !parts.isEmpty { return parts }
    return queue.isEmpty ? playback.detail?.collection?.items ?? [] : queue
  }
  var hasNext: Bool {
    PlaybackSequence.next(detail: playback.detail, cid: playback.selectedCID, queue: queue, parts: true, collection: true) != nil
  }
  func next() {
    guard let item = PlaybackSequence.next(detail: playback.detail, cid: playback.selectedCID,
      queue: queue, parts: true, collection: true) else { return }
    advance(to: item)
  }
  func advance(to item: PlaybackQueueItem) {
    if item.bvid == playback.detail?.video.bvid, let cid = item.cid {
      playerNavigation.current?.cid = cid
      playback.selectPage(cid, api: api, resume: 0)
      return
    }
    let visit = MobileVideoVisit(bvid: item.bvid, cid: item.cid)
    visit.resume = PlaybackResume(position: 0, playing: true)
    visit.queue = queue.isEmpty ? playback.detail?.collection?.items ?? [] : queue
    // Advancing a sequence replaces the active visit; it must not grow the back stack or present UI in the background.
    captureVisit()
    if let current = playerNavigation.current {
      if playerNavigation.root?.id == current.id { playerNavigation.root = visit }
      playerNavigation.path = playerNavigation.path.map { $0 == .video(current.id) ? .video(visit.id) : $0 }
      playerNavigation.visits.removeValue(forKey: current.id)?.comments.stop()
    } else { playerNavigation.root = visit }
    playerNavigation.visits[visit.id] = visit
    playerNavigation.active = visit.id
    queue = visit.queue
    loadVisit(visit)
  }
  func openSaved(_ entry: SavedDownload) {
    beginVisit(MobileVideoVisit(bvid: entry.video.bvid, cid: entry.cid, local: entry))
  }
  func closePlayback() {
    mobilePiP.controller?.stopPictureInPicture()
    audioTask?.cancel()
    isPlaybackOpen = false
    resumeAfterInterruption = false
    nowPlaying?.update()
    playerNavigation.reset()
    playback.stop()
    comments.stop()
    extras.reset()
    danmaku.stop()
    showPlayer = false
  }
  func refreshAccount() async {
    guard !checkingAccount else { return }
    checkingAccount = true
    let generation = api.authenticationGeneration
    defer { checkingAccount = false }
    do {
      let result = try await LoginRestoration.check(api: api, previous: account)
      guard generation == api.authenticationGeneration else { return }
      account = result.account
      accountRestoreMessage = result.message
      accountNeedsRetry = result.shouldRetry
    } catch {
      // A disappearing window or logout must not replace a newer account.
      if Task.isCancelled, generation == api.authenticationGeneration, api.signedIn { accountNeedsRetry = true }
    }
  }
  func retryAccountRestoration() async {
    for delay in [2, 5, 10] {
      guard accountNeedsRetry else { return }
      do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      await refreshAccount()
    }
  }
  func clearAccountRestorationMessage() {
    accountRestoreMessage = nil
    accountNeedsRetry = false
  }
  func login() {
    showLogin = true
    refreshQR()
  }
  func refreshQR() {
    closeLogin()
    loginExpired = false
    loginStatus = "正在获取二维码"
    loginGeneration = api.authenticationGeneration
    loginTask = Task {
      do {
        let qr = try await api.appCoinQRCode()
        try Task.checkCancellation()
        guard loginGeneration == api.authenticationGeneration else { throw CancellationError() }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(qr.url.utf8)
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
          let rendered = CIContext().createCGImage(image, from: image.extent) else {
          throw BiliError(text: "二维码生成失败，请刷新")
        }
        qrImage = rendered
        loginCode = qr.code
        loginDeadline = Date().addingTimeInterval(180)
        await pollLogin(code: qr.code)
      } catch {
        guard !Task.isCancelled else { return }
        loginStatus = error.localizedDescription
        loginExpired = true
      }
    }
  }
  // Keep the same QR challenge while the user switches to the official app to scan it.
  func pauseLogin() {
    guard showLogin, !loginExpired else { return }
    loginPaused = true
    loginTask?.cancel()
    loginTask = nil
  }
  func resumeLogin() {
    guard showLogin, loginPaused else { return }
    loginPaused = false
    guard let code = loginCode else { refreshQR(); return }
    loginTask = Task { await pollLogin(code: code) }
  }
  private func pollLogin(code: String) async {
    while !Task.isCancelled, loginGeneration == api.authenticationGeneration, loginCode == code {
      guard Date() < loginDeadline else {
        loginExpired = true; loginStatus = "二维码已过期，请刷新后重新扫码"; return
      }
      do {
        if let login = try await api.pollClientLogin(code) {
          try Task.checkCancellation()
          guard loginGeneration == api.authenticationGeneration, loginCode == code else { return }
          try api.saveClientLogin(login)
          clearAccountRestorationMessage()
          let mid = login.appCoinAuthorization!.accountID
          account = Account(name: account?.mid == mid ? account!.name : "已登录", mid: mid,
            face: account?.mid == mid ? account!.face : "")
          actions.clear(); inbox.clear(); messageUnread.reset(); accountHistory.reset(); historySync.reset()
          favoriteRevision += 1
          loginStatus = "已登录"
          qrImage = nil; loginCode = nil
          showLogin = false
          loginCompletion = UUID()
          let savedGeneration = api.authenticationGeneration
          Task { [weak self] in
            guard let self, let profile = try? await self.api.nav(),
              self.api.authenticationGeneration == savedGeneration else { return }
            self.account = profile
          }
          return
        }
        loginStatus = "使用哔哩哔哩 App 扫码，并确认登录"
      } catch {
        guard !Task.isCancelled else { return }
        let network = error as NSError
        let retryable = network.domain == NSURLErrorDomain && [
          NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
          NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
          NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorCancelled,
        ].contains(network.code)
        guard retryable else {
          loginStatus = error.localizedDescription; loginExpired = true; return
        }
        loginStatus = "连接暂时中断，正在恢复登录确认…"
      }
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
    }
  }
  func closeLogin() {
    loginTask?.cancel()
    loginTask = nil
    qrImage = nil
    loginCode = nil
    loginPaused = false
  }
  func logout() {
    closeLogin()
    closePlayback()
    api.logout()
    clearAccountRestorationMessage()
    account = nil
    actions.clear()
    inbox.clear(); messageUnread.reset()
    accountHistory.reset()
    historySync.reset()
  }
  func verify(_ title: String = "官方验证") {
    webTarget = WebTarget(url: URL(string: "https://www.bilibili.com/")!, title: title)
  }
  private func writeQA(suffix: String = "") async {
    var state: [String: Any] = [
      "date": Date().ISO8601Format(), "loading": playback.loading,
      "renderedFrame": playback.renderedFrame,
      "playing": playback.isPlaying, "position": playback.positionSeconds,
      "duration": playback.durationSeconds,
      "quality": playback.selectedQuality, "format": playback.sourceFormat,
      "error": playback.error ?? "", "buffering": playback.buffering,
      "danmaku": danmaku.items.count, "ready": playback.player.currentItem?.status == .readyToPlay,
      "boosting": playback.isBoosting, "rate": playback.player.rate, "speed": playback.speed,
      "applicationState": UIApplication.shared.applicationState.rawValue,
      "backgroundPlaybackEnabled": backgroundPlaybackEnabled,
      "lastAudioEvent": lastAudioEvent,
      "pictureInPictureActive": mobilePiP.controller?.isPictureInPictureActive ?? false,
      "cid": playback.selectedCID,
      "partNumber": playback.detail?.pages.first(where: { $0.id == playback.selectedCID })?.number ?? 0,
      "nowPlayingTitle": MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String ?? "",
      "specialScripts": specialScripts, "specialLayers": specialLayers,
      "unsupportedScripts": unsupportedScripts,
    ]
    state["signedIn"] = api.signedIn
    state["accountRestored"] = account != nil
    state["accountNeedsRetry"] = accountNeedsRetry
    state["accountRestoreMessage"] = accountRestoreMessage ?? ""
    state["unread"] = ["reply": messageUnread.counts.replies, "at": messageUnread.counts.mentions, "like": messageUnread.counts.likes, "private": messageUnread.counts.privateMessages, "error": messageUnread.error ?? ""]
    state["clientAuthorizationPresent"] = api.appCoinAuthorization != nil
    state["clientAuthorizationValid"] = api.appCoinAuthorization?.isValid(for: api.cookies["DedeUserID"]) == true
    state["network"] = await playback.networkStats()
    state["transfers"] = await playback.transferStats()
    state["danmakuPerformance"] = danmakuPerformance
    state["orientation"] = orientationDiagnostics
    state["startupMS"] = playback.startupMilliseconds
    state["sources"] = playback.routeDiagnostics
    state["failureCode"] = playback.failureCode
    state["cdnProbes"] = await playback.cdnAttempts()
    if qaTransferSamples.count < 12 {
      qaTransferSamples.append(["date": state["date"]!, "position": playback.positionSeconds, "transfers": state["transfers"]!, "network": state["network"]!])
    }
    state["startupSamples"] = qaTransferSamples
    state["bvid"] = playback.detail?.video.bvid ?? ""
    state["commentCount"] = comments.count
    state["commentCountLoaded"] = comments.hasLoadedCount
    state["metadataCommentCount"] = playback.detail?.counts.replies ?? -1
    let folder = AppPaths.support.appendingPathComponent("QA")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(
      withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: folder.appendingPathComponent("playback\(suffix).json"), options: .atomic)
    }
  }
  func writeGestureQA(_ phase: String) {
    #if DEBUG
      let args = ProcessInfo.processInfo.arguments
      guard args.contains("--qa-video") || args.contains("--qa-fixture") else { return }
      let folder = AppPaths.support.appendingPathComponent("QA")
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let state: [String: Any] = [
        "phase": phase, "boosting": playback.isBoosting,
        "rate": playback.player.rate, "speed": playback.speed,
        "temporarySpeed": playback.temporarySpeed,
      ]
      if let data = try? JSONSerialization.data(
        withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: folder.appendingPathComponent("boost-\(phase).json"), options: .atomic)
      }
    #endif
  }
  func writeFavoritesQA(_ editor: FavoriteEditor) {
    #if DEBUG
      guard ProcessInfo.processInfo.arguments.contains("--qa-favorites") else { return }
      let folder = AppPaths.support.appendingPathComponent("QA")
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let state: [String: Any] = [
        "loaded": editor.loaded, "folders": editor.folders.count,
        "selected": editor.selected.count, "error": editor.error ?? "",
      ]
      if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted]) {
        try? data.write(to: folder.appendingPathComponent("favorites.json"), options: .atomic)
      }
    #endif
  }
}

enum AppPaths {
  static var support: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BiliGlass")
  }
  static var cache: URL { support.appendingPathComponent("MediaCache") }
  static var transfers: URL { support.appendingPathComponent("Transfers") }
}

@main struct BilibiliMobileApp: App {
  @State private var store = Store()
  @Environment(\.scenePhase) private var phase
  var body: some Scene {
    WindowGroup {
      MobileRoot(store: store).tint(biliPink)
        .task { await store.start() }
        .task(id: "\(phase):\(store.accountNeedsRetry)") {
          guard phase == .active, store.accountNeedsRetry else { return }
          await store.retryAccountRestoration()
        }
        .task(id: "\(phase):\(store.api.authenticationGeneration):\(store.account?.mid ?? 0)") {
          guard store.account != nil else { store.messageUnread.reset(); return }
          guard phase == .active else { return }
          await store.messageUnread.poll(api: store.api)
        }
        .onOpenURL { url in
          if let bvid = videoID(url.absoluteString) {
            store.open(bvid)
          } else if url.scheme == "bilibilinext",
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(
              where: { $0.name == "bvid" })?.value, let bvid = videoID(raw)
          {
            store.open(bvid)
          }
        }
        .onChange(of: phase) { _, value in
          store.sceneChanged(value)
          if value != .active {
            store.playback.endTemporarySpeed()
            store.playback.saveCurrentProgress()
            store.persist()
          }
        }
    }
  }
}
