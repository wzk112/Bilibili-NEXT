import CoreImage.CIFilterBuiltins
import SwiftUI

struct HistoryEntry: Codable, Identifiable {
  var id: String { "\(accountID ?? "legacy"):\(video.bvid)" }
  var video: Video
  var positions: [String: Double]
  var date: Date
  var lastCID: Int?
  var accountID: String?
}
enum Destination: String, CaseIterable, Identifiable {
  case recommend = "推荐"
  case popular = "热门"
  case regions = "分区"
  case dynamic = "关注动态"
  case history = "观看记录"
  case favorites = "收藏"
  case later = "稍后再看"
  case downloads = "下载"
  case profile = "我的主页"
  case messages = "消息"
  case web = "更多"
  var id: String { rawValue }
  var icon: String {
    switch self {
    case .recommend: "house"
    case .popular: "flame"
    case .regions: "square.grid.2x2"
    case .dynamic: "person.2"
    case .history: "clock"
    case .favorites: "star"
    case .later: "text.badge.plus"
    case .downloads: "arrow.down.circle"
    case .profile: "person.crop.circle"
    case .messages: "bubble.left.and.bubble.right"
    case .web: "ellipsis.circle"
    }
  }
}
struct ProfileTarget: Identifiable { let id: Int }
private struct FeedSnapshot: Codable {
  let items: [Video]
  let page: Int
  let hasMore: Bool
  let date: Date
  let owner: String
}
@MainActor @Observable final class Store {
  let guide = FeatureGuideController()
  var loginUpgradeReason: LoginUpgradeReason?
  var loginUpgradeDismissed = false
  var preferencesTab = 0
  let api = API(loadCredentials: false)
  let playback = Playback()
  let fullscreen = FullscreenPlayerController()
  let downloads = Downloads()
  let comments = Comments()
  let videoActions = VideoActionsModel()
  let inbox = InboxModel()
  let messageUnread = MessageUnreadModel()
  let accountHistory = AccountHistory()
  let historySync = WatchHistorySync()
  let extras = VideoExtras()
  var playQueue: [PlaybackQueueItem] = []
  var queueTitle = "播放队列"
  var danmaku = DanmakuController()
  var navigationRevision = 0
  var profileTarget: ProfileTarget?
  var webTarget: WebTarget?
  var imageGallery: ImageGalleryTarget?
  var reportTarget: Video?
  var blockTarget: Video?
  var danmakuReportTarget: Danmaku?
  var blockedAuthors: Set<Int> = []
  var folders: [FavoriteFolder] = []
  var selectedFolder = 0
  var selectedRegion = 1005
  var libraryQuery = ""
  var interactionMessage: String?
  var destination: Destination = .recommend
  var searchFocus = 0
  var playerFocus = 0
  var videos: [Video] = []
  var history: [HistoryEntry] = []
  var query = ""
  var activeQuery = ""
  var searchOptions = SearchOptions()
  var searchUsers: [SearchUser] = []
  var searchHistory = UserDefaults.standard.stringArray(forKey: "searchHistory") ?? []
  var page = 1
  var hasMore = true
  var busy = false
  var feedMilliseconds = 0
  var error: String?
  var restoring = true
  var account: Account?
  var showLogin = false
  var showPlayer = false
  var isPlaybackOpen = false
  var showsMiniPlayer: Bool { isPlaybackOpen && !showPlayer && !fullscreen.isPresented }
  var qrImage: NSImage?
  var loginStatus = ""
  var loginExpired = false
  private var feedTask: Task<Void, Never>?
  private var loginTask: Task<Void, Never>?
  private var feedID = UUID()
  private var loadingFeedKey: String?
  private var feedSnapshots: [String: FeedSnapshot] = [:]
  private var browsePositions: [String: BrowsePosition] = [:]
  var browseKey: String { feedOwner + "|" + feedKey }
  var browsePosition: BrowsePosition {
    if let memory = browsePositions[browseKey] { return memory }
    let memory = BrowsePosition(); browsePositions[browseKey] = memory; return memory
  }
  private var feedKey: String {
    destination.rawValue + "|" + activeQuery
      + "|\(destination == .favorites ? selectedFolder : 0)|\(destination == .regions ? selectedRegion : 0)"
      + "|\(activeQuery.isEmpty ? "" : String(describing: searchOptions))|\(libraryQuery)"
  }
  private var feedOwner: String { api.cookies["DedeUserID"] ?? "guest" }
  init() {
    guide.store = self
    destination = Destination(rawValue: BrowsePreferences().resolvedStart.title) ?? .recommend
    if let data = UserDefaults.standard.data(forKey: "history") {
      history = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }
    inbox.onRead = { [weak self] in
      guard let self else { return }; await self.messageUnread.refresh(api: self.api)
    }
    playback.onProgress = { [weak self] bvid, cid, seconds, final in
      self?.saveProgress(bvid, cid: cid, seconds: seconds, final: final)
    }
    playback.onEnded = { [weak self] in
      guard let self else { return }
      if UserDefaults.standard.bool(forKey: "loopVideo") {
        self.playback.seek(to: 0); self.playback.player.playImmediately(atRate: self.playback.speed)
      } else if let next = PlaybackSequence.next(detail: self.playback.detail, cid: self.playback.selectedCID,
        queue: self.playQueue, parts: (UserDefaults.standard.object(forKey: "autoPlayParts") == nil || UserDefaults.standard.bool(forKey: "autoPlayParts")),
        collection: UserDefaults.standard.bool(forKey: "autoPlayNext")) {
        self.playQueueItem(next, present: self.showPlayer, automatic: true)
      }
    }
  }
  func start() async {
    await api.restoreCredentials()
    loginUpgradeReason = LoginUpgradeReason.evaluate(cookies: api.cookies, authorization: api.appCoinAuthorization)
    if !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--") }) {
      guide.scheduleAutomaticPresentation()
    }
    if UserDefaults.standard.string(forKey: "danmakuCloudOwner") != feedOwner {
      UserDefaults.standard.removeObject(forKey: "danmakuCloudRules")
    }
    if destination == .recommend, let data = UserDefaults.standard.data(forKey: "homeFeedSnapshot"),
      let cached = try? JSONDecoder().decode(FeedSnapshot.self, from: data),
      cached.owner == feedOwner, Date().timeIntervalSince(cached.date) < 86_400 {
      videos = cached.items
    }
    // Account validation and the signed feed share one navigation request.
    async let restoredAccount = api.nav()
    reload()
    account = try? await restoredAccount
    restoring = false
  }
  func reload() {
    if destination == .history && !showPlayer {
      if UserDefaults.standard.string(forKey: "historySource") != "local" {
        Task { await accountHistory.load(api: api, refresh: true) }
      }
      return
    }
    guard !busy || loadingFeedKey != feedKey else { return }
    browsePosition.reset()
    feedTask?.cancel()
    feedID = UUID()
    let token = feedID
    page = 1
    hasMore = true
    error = nil
    busy = true
    loadingFeedKey = feedKey
    let began = ContinuousClock.now
    feedTask = Task {
      do {
        if !activeQuery.isEmpty && searchOptions.users {
          let result = try await api.searchUsers(activeQuery, page: 1)
          guard token == feedID, !Task.isCancelled else { return }
          searchUsers = result; videos = []; hasMore = !result.isEmpty; busy = false; loadingFeedKey = nil
          return
        }
        let items =
          try await (activeQuery.isEmpty ? feed(page: 1) : api.search(activeQuery, page: 1, options: searchOptions))
        try Task.checkCancellation()
        guard token == feedID else { return }
        videos = Video.deduplicated(items)
        hasMore =
          destination == .dynamic
          ? api.dynamicHasMore : destination != .later && !items.isEmpty
        busy = false
        loadingFeedKey = nil
        let elapsed = began.duration(to: .now).components
        feedMilliseconds = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        rememberFeed()
      } catch {
        guard token == feedID, !Task.isCancelled else { return }
        busy = false
        loadingFeedKey = nil
        self.error = error.localizedDescription
      }
    }
  }
  func search() {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !term.isEmpty { searchHistory.removeAll { $0 == term }; searchHistory.insert(term, at: 0); searchHistory = Array(searchHistory.prefix(30)); UserDefaults.standard.set(searchHistory, forKey: "searchHistory") }
    if let bv = videoID(term) {
      open(bv)
      return
    }
    videoActions.clear()
    comments.stop()
    danmaku.stop()
    playback.personAvoidance.stop()
    navigationRevision += 1
    profileTarget = nil
    destination = .popular
    showPlayer = false
    playback.saveCurrentProgress()
    activeQuery = term
    videos = []
    searchUsers = []
    reload()
  }
  func clearSearch() {
    query = ""
    guard !showPlayer else { return }
    activeQuery = ""
    reload()
  }
  func openSaved(_ entry: SavedDownload) {
    isPlaybackOpen = true
    extras.reset(); playQueue = []; queueTitle = ""
    navigationRevision += 1
    profileTarget = nil
    videoActions.clear(); comments.stop(); danmaku.stop()
    showPlayer = true
    playerFocus += 1
    playback.focusPlayer()
    playback.openLocal(URL(fileURLWithPath: entry.path), video: entry.video, cid: entry.cid,
      sidecar: entry.danmakuPath.map { URL(fileURLWithPath: $0) })
    let token = playback.generation
    // Cached playback starts immediately; optional online metadata enables comments
    // and interactions without replacing the local media or requiring a connection.
    Task {
      guard let detail = try? await api.detail(entry.video.bvid), playback.generation == token,
        playback.isOffline else { return }
      playback.detail = detail
    }
  }
  func more() {
    guard !busy, hasMore else { return }
    busy = true
    loadingFeedKey = feedKey
    let token = feedID
    let next = page + 1
    error = nil
    feedTask = Task {
      do {
        if !activeQuery.isEmpty && searchOptions.users {
          let result = try await api.searchUsers(activeQuery, page: next)
          guard token == feedID, !Task.isCancelled else { return }
          let ids = Set(searchUsers.map(\.id)); searchUsers += result.filter { !ids.contains($0.id) }
          page = next; hasMore = !result.isEmpty && searchUsers.count > ids.count; busy = false; loadingFeedKey = nil
          return
        }
        let items =
          try await (activeQuery.isEmpty ? feed(page: next) : api.search(activeQuery, page: next, options: searchOptions))
        try Task.checkCancellation()
        guard token == feedID else { return }
        let ids = Set(videos.map(\.id))
        videos += Video.deduplicated(items, excluding: ids)
        page = next
        hasMore =
          destination == .dynamic
          ? api.dynamicHasMore : !items.isEmpty && videos.count > ids.count
        busy = false
        loadingFeedKey = nil
        rememberFeed()
      } catch {
        guard token == feedID, !Task.isCancelled else { return }
        busy = false
        loadingFeedKey = nil
        self.error = error.localizedDescription
      }
    }
  }
  func showProfile(_ mid: Int) {
    navigationRevision += 1
    profileTarget = ProfileTarget(id: mid)
  }
  func open(_ bvid: String, initialCID: Int? = nil, keepQueue: Bool = false, present: Bool = true, continuing: Bool = false) {
    isPlaybackOpen = true
    if !keepQueue { playQueue = []; queueTitle = "" }
    extras.reset()
    videoActions.clear()
    if present { navigationRevision += 1; profileTarget = nil }
    comments.stop()
    danmaku.stop()
    if present { showPlayer = true; playerFocus += 1; playback.focusPlayer() }
    playback.open(bvid, api: api, initialCID: initialCID, restoring: continuing ? PlaybackResume(position: 0, playing: true) : nil) { [weak self] cid in self?.position(bvid, cid: cid) ?? 0 }
  }
  var currentQueue: [PlaybackQueueItem] {
    let parts = PlaybackSequence.parts(playback.detail)
    if !parts.isEmpty { return parts }
    if !playQueue.isEmpty { return playQueue }
    return playback.detail?.collection?.items ?? playQueue
  }
  var currentQueueTitle: String {
    if (playback.detail?.pages.count ?? 0) > 1 { return "视频分 P" }
    if !playQueue.isEmpty { return queueTitle.isEmpty ? "播放列表" : queueTitle }
    return playback.detail?.collection?.title ?? "播放列表"
  }
  private var queueIndex: Int? {
    currentQueue.firstIndex { $0.bvid == playback.detail?.video.bvid && ($0.cid == nil || $0.cid == playback.selectedCID) }
  }
  var hasNextVideo: Bool {
    PlaybackSequence.next(detail: playback.detail, cid: playback.selectedCID, queue: playQueue, parts: true, collection: true) != nil
  }
  func playNext(present: Bool = true) {
    guard let next = PlaybackSequence.next(detail: playback.detail, cid: playback.selectedCID,
      queue: playQueue, parts: true, collection: true) else { return }
    playQueueItem(next, present: present, automatic: true)
  }
  func playQueueItem(_ item: PlaybackQueueItem, present: Bool = true, automatic: Bool = false) {
    if item.bvid == playback.detail?.video.bvid, let cid = item.cid {
      playback.selectPage(cid, api: api, resume: automatic ? 0 : position(item.bvid, cid: cid))
    } else { open(item.bvid, initialCID: item.cid, keepQueue: true, present: present, continuing: automatic) }
  }
  func openFeedVideo(_ video: Video) {
    let queue = videos.map { PlaybackQueueItem(bvid: $0.bvid, title: $0.title) }
    let title = destination.rawValue
    open(video.bvid)
    if [.later, .favorites].contains(destination) { playQueue = queue; queueTitle = title }
  }
  func openHistory(_ entry: AccountHistoryEntry) {
    isPlaybackOpen = true
    extras.reset(); playQueue = []; queueTitle = ""
    videoActions.clear(); navigationRevision += 1; profileTarget = nil
    comments.stop(); danmaku.stop(); showPlayer = true; playerFocus += 1
    playback.focusPlayer()
    playback.open(entry.video.bvid, api: api, initialCID: entry.cid) { [weak self] cid in
      if entry.isLocal && entry.cid == 0 { return self?.position(entry.video.bvid, cid: cid) ?? 0 }
      return cid == entry.cid ? Double(max(0, entry.progress)) : 0
    }
  }
  func position(_ bvid: String, cid: Int) -> Double {
    history.first { $0.video.bvid == bvid && ($0.accountID == feedOwner || $0.accountID == nil) }?.positions["\(cid)"] ?? 0
  }
  func saveProgress(_ bvid: String, cid: Int, seconds: Double, final: Bool = false) {
    guard let detail = playback.detail, detail.video.bvid == bvid, cid > 0,
      seconds.isFinite, seconds > 0 else { return }
    let video = detail.video
    var entry =
      history.first { $0.video.bvid == bvid && ($0.accountID == feedOwner || $0.accountID == nil) }
      ?? HistoryEntry(video: video, positions: [:], date: Date())
    entry.video = video
    entry.positions["\(cid)"] = seconds
    entry.date = Date()
    entry.lastCID = cid
    entry.accountID = feedOwner
    history.removeAll { $0.video.bvid == bvid && ($0.accountID == feedOwner || $0.accountID == nil) }
    history.insert(entry, at: 0)
    history = Array(history.prefix(200))
    persistHistory()
    historySync.record(api: api, aid: detail.aid, bvid: bvid, cid: cid, seconds: seconds, final: final)
  }
  func persistHistory() {
    if let d = try? JSONEncoder().encode(history) {
      UserDefaults.standard.set(d, forKey: "history")
    }
  }
  func navigate(_ dest: Destination) {
    if destination == dest && activeQuery.isEmpty {
      if showPlayer { leavePlayer() }
      return
    }
    rememberFeed()
    searchUsers = []; libraryQuery = ""
    feedTask?.cancel(); feedID = UUID(); busy = false; loadingFeedKey = nil
    videoActions.clear()
    navigationRevision += 1
    profileTarget = nil
    destination = dest
    activeQuery = ""
    query = ""
    videos = []
    showPlayer = false
    playback.saveCurrentProgress()
    comments.stop()
    danmaku.stop()
    playback.personAvoidance.stop()
    if let cached = feedSnapshots[browseKey], cached.owner == feedOwner,
      !(dest == .recommend && UserDefaults.standard.bool(forKey: "refreshHomeOnReturn")) {
      videos = cached.items; page = cached.page; hasMore = cached.hasMore; error = nil
    } else if [.recommend, .popular, .regions, .dynamic, .favorites, .later].contains(dest) { reload() }
  }
  func returnToPlayer() {
    guard isPlaybackOpen else { return }
    profileTarget = nil; navigationRevision += 1
    showPlayer = true; playerFocus += 1; playback.focusPlayer()
  }
  func leavePlayer() {
    navigationRevision += 1; showPlayer = false
    playback.saveCurrentProgress(); playback.personAvoidance.stop()
    danmaku.stop(); comments.stop()
    if destination == .recommend && activeQuery.isEmpty && UserDefaults.standard.bool(forKey: "refreshHomeOnReturn") { reload() }
  }
  func closeMiniPlayer() {
    playback.stop(); isPlaybackOpen = false; showPlayer = false
    danmaku.stop(); comments.stop(); videoActions.clear(); extras.reset()
    playQueue = []; queueTitle = ""
  }
  func selectRegion(_ id: Int) {
    guard selectedRegion != id else { return }
    rememberFeed()
    selectedRegion = id
    videos = []; error = nil
    if let cached = feedSnapshots[browseKey], cached.owner == feedOwner {
      feedTask?.cancel(); feedID = UUID(); busy = false; loadingFeedKey = nil
      videos = cached.items; page = cached.page; hasMore = cached.hasMore
    } else { reload() }
  }
  private func rememberFeed() {
    guard activeQuery.isEmpty, [.recommend, .popular, .regions].contains(destination), !videos.isEmpty, !busy else { return }
    let snapshot = FeedSnapshot(items: videos, page: page, hasMore: hasMore, date: Date(), owner: feedOwner)
    feedSnapshots[browseKey] = snapshot
    if destination == .recommend, page == 1, let data = try? JSONEncoder().encode(snapshot) {
      UserDefaults.standard.set(data, forKey: "homeFeedSnapshot")
    }
  }
  func feed(page: Int) async throws -> [Video] {
    switch destination {
    case .recommend: return try await api.recommendations(page: page)
    case .popular: return try await api.popular(page: page)
    case .regions: return try await api.regionVideos(selectedRegion, page: page)
    case .dynamic:
      guard account != nil else { throw BiliError(text: "登录后查看关注动态") }
      return try await api.followedVideos(page: page)
    case .favorites:
      guard let account else { throw BiliError(text: "登录后查看收藏") }
      if folders.isEmpty { folders = try await api.favoriteFolders(account.mid) }
      if selectedFolder == 0 { selectedFolder = folders.first?.id ?? 0 }
      guard selectedFolder > 0 else { return [] }
      return try await api.favorites(selectedFolder, page: page, keyword: libraryQuery)
    case .later:
      guard account != nil else { throw BiliError(text: "登录后查看稍后再看") }
      return page == 1 ? try await api.later() : []
    default: return []
    }
  }
  func addLater(_ aid: Int) async {
    do {
      _ = try await api.post("/x/v2/history/toview/add", ["aid": "\(aid)"])
      interactionMessage = "已加入稍后再看"
    } catch { interactionMessage = error.localizedDescription }
  }
  func login() {
    showLogin = true
    refreshQR()
  }
  func refreshQR() {
    loginTask?.cancel()
    qrImage = nil
    loginExpired = false
    loginStatus = "正在获取二维码"
    loginTask = Task {
      do {
        let generation = api.authenticationGeneration
        let qr = try await api.appCoinQRCode()
        try Task.checkCancellation()
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(qr.url.utf8)
        guard let ci = filter.outputImage,
          let cg = CIContext().createCGImage(ci.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            from: ci.extent.applying(CGAffineTransform(scaleX: 8, y: 8))) else { throw BiliError(text: "二维码生成失败") }
        qrImage = NSImage(cgImage: cg, size: NSSize(width: 208, height: 208))
        loginStatus = "使用哔哩哔哩 App 扫码，并在手机确认"
        for _ in 0..<90 {
          try await Task.sleep(for: .seconds(2))
          try Task.checkCancellation()
          guard api.authenticationGeneration == generation else { throw CancellationError() }
          if let login = try await api.pollClientLogin(qr.code) {
            try Task.checkCancellation()
            try api.saveClientLogin(login)
            loginUpgradeReason = nil
            loginUpgradeDismissed = false
            videoActions.clear()
            // The confirmed login remains usable if profile loading is temporarily offline.
            let mid = login.appCoinAuthorization!.accountID
            account = Account(name: account?.mid == mid ? account!.name : "已登录", mid: mid,
              face: account?.mid == mid ? account!.face : "")
            if let profile = try? await api.nav(), api.cookies["DedeUserID"] == String(mid) { account = profile }
            try Task.checkCancellation()
            loginStatus = "已登录"
            showLogin = false
            if !showPlayer { reload() }
            return
          }
        }
        loginExpired = true
        loginStatus = "二维码已过期"
      } catch {
        if !Task.isCancelled {
          loginStatus = error.localizedDescription
          loginExpired = true
        }
      }
    }
  }
  func closeLogin() {
    loginTask?.cancel()
    loginTask = nil
    qrImage = nil
  }
  func logout() {
    isPlaybackOpen = false
    extras.reset(); playQueue = []; queueTitle = ""; searchUsers = []; libraryQuery = ""
    blockedAuthors = []; reportTarget = nil; blockTarget = nil; danmakuReportTarget = nil
    UserDefaults.standard.removeObject(forKey: "danmakuCloudRules")
    UserDefaults.standard.removeObject(forKey: "danmakuCloudOwner")
    feedTask?.cancel(); feedID = UUID(); busy = false; loadingFeedKey = nil
    feedSnapshots.removeAll(); browsePositions.removeAll()
    UserDefaults.standard.removeObject(forKey: "homeFeedSnapshot")
    videoActions.clear()
    inbox.clear(); messageUnread.reset()
    accountHistory.reset()
    playback.stop()
    historySync.reset()
    showPlayer = false
    navigationRevision += 1
    profileTarget = nil
    api.logout()
    loginUpgradeReason = nil
    loginUpgradeDismissed = false
    destination = .recommend
    activeQuery = ""; query = ""
    account = nil
    videos = []
    folders = []
    selectedFolder = 0
    comments.stop()
    danmaku.stop()
    reload()
  }
}
