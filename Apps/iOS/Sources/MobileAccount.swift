import PhotosUI
import SwiftUI
import WebKit

@MainActor final class WebSession {
  static let shared = WebSession()
  let dataStore = WKWebsiteDataStore.nonPersistent()
  func prepare(api: API) async {
    for (name, value) in api.cookies {
      var properties: [HTTPCookiePropertyKey: Any] = [
        .domain: ".bilibili.com", .path: "/", .name: name, .value: value, .secure: "TRUE",
      ]
      if name == "SESSDATA" { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
      if let cookie = HTTPCookie(properties: properties) {
        await dataStore.httpCookieStore.setCookie(cookie)
      }
    }
  }
  func reset() {
    dataStore.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast,
      completionHandler: {})
  }
}
@MainActor @Observable final class MobileWebNavigation {
  weak var webView: WKWebView?
  var canGoBack = false
  var canGoForward = false
  func update(_ web: WKWebView) {
    canGoBack = web.canGoBack
    canGoForward = web.canGoForward
  }
}
struct MobileOfficialWeb: UIViewRepresentable {
  let target: WebTarget
  @Bindable var store: Store
  @Binding var error: String?
  @Binding var loading: Bool
  let navigation: MobileWebNavigation
  func makeCoordinator() -> Coordinator {
    Coordinator(store: store, error: $error, loading: $loading, navigation: navigation)
  }
  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = WebSession.shared.dataStore
    config.defaultWebpagePreferences.preferredContentMode = .desktop
    let web = WKWebView(frame: .zero, configuration: config)
    web.customUserAgent = API.userAgent
    web.navigationDelegate = context.coordinator
    web.allowsBackForwardNavigationGestures = true
    navigation.webView = web
    config.websiteDataStore.httpCookieStore.add(context.coordinator)
    context.coordinator.task = Task { @MainActor in
      await WebSession.shared.prepare(api: store.api)
      guard !Task.isCancelled else { return }
      web.load(URLRequest(url: target.url))
    }
    return web
  }
  func updateUIView(_ view: WKWebView, context: Context) {}
  static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.task?.cancel()
    view.stopLoading()
    view.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
    view.navigationDelegate = nil
  }
  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
    let store: Store
    var generation: UUID
    @Binding var error: String?
    @Binding var loading: Bool
    var task: Task<Void, Never>?
    let navigation: MobileWebNavigation
    init(
      store: Store, error: Binding<String?>, loading: Binding<Bool>, navigation: MobileWebNavigation
    ) {
      self.navigation = navigation
      self.store = store
      generation = store.api.authenticationGeneration
      _error = error
      _loading = loading
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = action.request.url else {
        decisionHandler(.cancel)
        return
      }
      if action.targetFrame?.isMainFrame == false && url.scheme == "https" {
        decisionHandler(.allow)
        return
      }
      if url.scheme == "about" {
        decisionHandler(.allow)
        return
      }
      guard url.scheme == "https", let host = url.host?.lowercased(),
        host == "bilibili.com" || host.hasSuffix(".bilibili.com") || host == "biligame.com"
          || host.hasSuffix(".biligame.com")
      else {
        if action.navigationType == .linkActivated {
          error = "这个链接无法在验证面板打开，可返回使用二维码登录。"
        }
        loading = false
        decisionHandler(.cancel)
        return
      }
      if action.targetFrame == nil {
        webView.load(action.request)
        decisionHandler(.cancel)
      } else {
        decisionHandler(.allow)
      }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      loading = true
      error = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      loading = false
      self.navigation.update(webView)
      cookiesDidChange(in: webView.configuration.websiteDataStore.httpCookieStore)
    }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError failure: Error
    ) {
      if (failure as NSError).code != NSURLErrorCancelled {
        loading = false
        error = failure.localizedDescription
      }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error)
    {
      if (failure as NSError).code != NSURLErrorCancelled {
        loading = false
        error = failure.localizedDescription
        self.navigation.update(webView)
      }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      self.navigation.update(webView)
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
      cookieStore.getAllCookies { [weak self] cookies in
        Task { @MainActor in
          guard let self, self.store.api.authenticationGeneration == self.generation else { return }
          let auth: Set<String> = [
            "SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid",
          ]
          var webCookies: [String: String] = [:]
          for cookie in cookies
          where (cookie.domain == ".bilibili.com" || cookie.domain == "bilibili.com")
            && (cookie.expiresDate.map { $0 > Date() } ?? true) {
            if auth.contains(cookie.name) { webCookies[cookie.name] = cookie.value }
            else if API.interactionCookieNames.contains(cookie.name) {
              self.store.api.cookies[cookie.name] = cookie.value
            }
          }
          // Cookie observers can fire while WebKit is still importing the session.
          guard webCookies["SESSDATA"] != nil, webCookies["bili_jct"] != nil,
            webCookies["DedeUserID"] != nil,
            webCookies != self.store.api.cookies.filter({ auth.contains($0.key) }) else { return }
          do {
            try self.store.api.saveWebLogin(webCookies)
            self.store.clearAccountRestorationMessage()
            self.generation = self.store.api.authenticationGeneration
            let savedGeneration = self.generation
            let mid = Int(webCookies["DedeUserID"]!)!
            self.store.account = Account(name: "已登录", mid: mid, face: "")
            self.store.actions.clear(); self.store.inbox.clear(); self.store.accountHistory.reset()
            self.store.historySync.reset(); self.store.favoriteRevision += 1
            if let profile = try? await self.store.api.nav(),
              self.store.api.authenticationGeneration == savedGeneration {
              self.store.account = profile
            }
            guard self.store.api.authenticationGeneration == savedGeneration else { return }
            self.store.loginCompletion = UUID()
          } catch { self.error = error.localizedDescription }
        }
      }
    }
  }
}
struct MobileWebPage: View {
  @Bindable var store: Store
  let target: WebTarget
  @State private var error: String?
  @State private var navigation = MobileWebNavigation()
  @State private var loading = true
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      VStack {
        if let error {
          MobileError(text: error) {
            self.error = nil
            navigation.webView?.reload()
          }
        }
        if loading { ProgressView("正在加载官方页面").padding(12) }
        MobileOfficialWeb(
          target: target, store: store, error: $error, loading: $loading, navigation: navigation)
      }.navigationTitle(target.title).navigationBarTitleDisplayMode(.inline).toolbar {
        ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
        ToolbarItemGroup(placement: .bottomBar) {
          Button {
            navigation.webView?.goBack()
          } label: {
            Image(systemName: "chevron.left")
          }
          .disabled(!navigation.canGoBack).accessibilityLabel("网页上一页")
          Button {
            navigation.webView?.goForward()
          } label: {
            Image(systemName: "chevron.right")
          }
          .disabled(!navigation.canGoForward).accessibilityLabel("网页下一页")
          Spacer()
          Button {
            navigation.webView?.reload()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .accessibilityLabel("刷新网页")
        }
      }
    }
  }
}
struct MobileLogin: View {
  @Bindable var store: Store
  @State private var web = false
  @Environment(\.scenePhase) private var loginPhase
  @State private var saving = false
  @State private var saveMessage: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 14) {
          Text("使用哔哩哔哩 App 扫码并确认。也可以保存二维码，在哔哩哔哩扫一扫中从相册选择。").font(.callout)
            .foregroundStyle(.secondary).multilineTextAlignment(.center)
          ZStack {
            RoundedRectangle(cornerRadius: 20).fill(.white)
            if let image = store.qrImage {
              Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                .padding(16).opacity(store.loginExpired ? 0.15 : 1)
            } else if !store.loginExpired { ProgressView() }
            if store.loginExpired { Button("刷新二维码") { store.refreshQR() }.buttonStyle(.glass) }
          }.frame(width: 220, height: 220).accessibilityIdentifier("login-qr")
          Text(store.loginStatus).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .accessibilityIdentifier("login-status")
          Button(saving ? "正在保存…" : "保存二维码到相册") { Task { await saveQR() } }
            .buttonStyle(.glassProminent).disabled(store.qrImage == nil || store.loginExpired || saving)
          if let saveMessage { Text(saveMessage).font(.caption).foregroundStyle(.secondary) }
          Text("登录信息仅保存在本机钥匙串。取消后保留原登录。").font(.caption).foregroundStyle(.secondary)
          DisclosureGroup("其他登录方式") {
            VStack(spacing: 12) {
              Button("使用网页登录") { store.closeLogin(); web = true }.buttonStyle(.glass)
              Text("网页登录使用网页投币通道；如遇非法访问，请使用上方扫码登录获取客户端授权。")
                .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 12)
          }
        }.padding(24)
      }.navigationTitle("登录").navigationBarTitleDisplayMode(.inline).toolbar {
        Button("关闭") { dismiss() }
      }
      .sheet(isPresented: $web, onDismiss: {
        if !store.loginExpired && store.qrImage == nil { store.refreshQR() }
      }) {
        MobileWebPage(store: store,
          target: WebTarget(url: URL(string: "https://passport.bilibili.com/login")!, title: "官方登录"))
      }
      .onChange(of: store.loginCompletion) { dismiss() }
      .onChange(of: loginPhase) { _, phase in
        guard !web else { return }
        if phase == .active { store.resumeLogin() } else { store.pauseLogin() }
      }
    }
  }
  private func saveQR() async {
    guard let image = store.qrImage, !store.loginExpired, !saving else { return }
    saving = true; saveMessage = nil
    defer { saving = false }
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
      saveMessage = "未获得相册添加权限。可以截图保存，或在系统设置中允许添加照片。"
      return
    }
    // Include the QR quiet zone in the saved image, just as in the on-screen card.
    let qr = UIImage(cgImage: image)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: qr.size.width + 64, height: qr.size.height + 64))
    let framed = renderer.image { context in
      UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: CGSize(width: qr.size.width + 64, height: qr.size.height + 64)))
      context.cgContext.interpolationQuality = .none
      qr.draw(at: CGPoint(x: 32, y: 32))
    }
    do {
      try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: framed) }
      saveMessage = "已保存。请在二维码过期前，用哔哩哔哩扫一扫选择这张图片。"
    } catch { saveMessage = error.localizedDescription }
  }
}
struct MobileAccount: View {
  @Bindable var store: Store
  private var navigation = NavigationCustomization()
  var body: some View {
    List {
      Section {
        if let account = store.account {
          NavigationLink {
            MobileProfile(store: store, mid: account.mid)
          } label: {
            HStack(spacing: 14) {
              MobileAvatar(url: account.face).frame(width: 58, height: 58).clipShape(.circle)
              VStack(alignment: .leading, spacing: 5) {
                Text(account.name).font(.title3.bold())
                Text("UID \(account.mid)").font(.caption).foregroundStyle(.secondary)
              }
            }.padding(.vertical, 8)
          }
        } else {
          Button {
            store.login()
          } label: {
            Label(store.restoring ? "恢复登录中" : "登录哔哩哔哩", systemImage: "person.crop.circle")
          }.disabled(store.restoring)
        }
      }
      if let message = store.accountRestoreMessage {
        Section {
          Text(message).font(.footnote).foregroundStyle(.secondary)
          if store.accountNeedsRetry {
            Button("重试登录状态检查") { Task { await store.refreshAccount() } }
              .accessibilityIdentifier("retry-account-restoration")
          }
        }
      }
      if navigation.preferences.visible.contains(where: \.isLibrary) {
        Section("我的资料库") { MobileLibraryLinks(store: store) }
      }
      Section {
        NavigationLink("设置", systemImage: "gearshape") { MobileSettings(store: store) }
        if store.account != nil {
          Button("账户信息") {
            store.webTarget = WebTarget(
              url: URL(string: "https://account.bilibili.com/account/home")!, title: "账户信息")
          }
        }
      }
      Section("官方服务") {
        Link("番剧", destination: URL(string: "https://www.bilibili.com/anime/")!)
        Link("直播", destination: URL(string: "https://live.bilibili.com/")!)
        Link("创作中心", destination: URL(string: "https://member.bilibili.com/platform/home")!)
      }
      if store.account != nil {
        Section {
          Button("重新登录") { store.login() }
          Button("退出登录", role: .destructive) { store.logout() }
        }
      }
    }.navigationTitle("我的")
  }
}
struct MobileLibrary: View {
  @Bindable var store: Store
  var body: some View {
    List { Section { MobileLibraryLinks(store: store) } }.navigationTitle("资料库")
  }
}
struct MobileLibraryLinks: View {
  @Bindable var store: Store
  private var navigation = NavigationCustomization()
  var body: some View {
    ForEach(navigation.preferences.visible.filter(\.isLibrary)) { page in
      NavigationLink { MobileLibraryDestination(store: store, page: page) } label: {
        Label(page.title, systemImage: page.symbol)
      }.accessibilityIdentifier("library-\(page.rawValue)")
    }
  }
}
struct MobileLibraryDestination: View {
  @Bindable var store: Store
  let page: StartPage
  var body: some View {
    switch page {
    case .history: MobileHistory(store: store)
    case .favorites: MobileFavorites(store: store)
    case .downloads: MobileDownloadsPage(store: store)
    case .later:
      MobileVideoList(title: "稍后再看", store: store) { page in
        page == 1 ? try await store.api.later() : []
      }
    default: MobileAccount(store: store)
    }
  }
}
struct MobileFavorites: View {
  @Bindable var store: Store
  @State private var folders: [FavoriteFolder] = []
  @State private var error: String?
  @State private var loading = false
  @State private var generation = UUID()
  var body: some View {
    List {
      if store.account == nil { Button("登录后查看收藏") { store.login() } }
      ForEach(folders) { folder in
        NavigationLink {
          MobileVideoList(title: folder.title, store: store) { page in
            try await store.api.favorites(folder.id, page: page)
          }
        } label: {
          Label {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(folder.title)
                Text(folder.isPrivate ? "私密" : "公开").font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text("\(folder.count)").foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: folder.isPrivate ? "lock" : "folder")
          }
        }
      }
      if loading { ProgressView("正在加载收藏夹") }
      if store.account != nil && folders.isEmpty && !loading && error == nil {
        ContentUnavailableView(
          "还没有收藏夹", systemImage: "folder",
          description: Text("可以在视频的收藏面板中新建收藏夹。"))
      }
      if let error { MobileError(text: error) { Task { await load() } } }
    }.navigationTitle("收藏").task(id: store.account?.mid) { await load() }.refreshable {
      await load()
    }.task(id: store.favoriteRevision) { if store.favoriteRevision > 0 { await load() } }
  }
  private func load() async {
    generation = UUID()
    let token = generation
    guard let account = store.account else {
      loading = false
      folders = []
      error = nil
      return
    }
    loading = true
    error = nil
    let owner = store.api.authenticationGeneration
    defer { if token == generation { loading = false } }
    do {
      let result = try await store.api.favoriteFolders(account.mid)
      try Task.checkCancellation()
      guard token == generation, owner == store.api.authenticationGeneration else { return }
      folders = result
    } catch {
      if token == generation && owner == store.api.authenticationGeneration
        && !(error is CancellationError)
      {
        self.error = error.localizedDescription
      }
    }
  }
}
struct MobileHistory: View {
  @Bindable var store: Store
  @State private var local = false
  private var rows: [AccountHistoryEntry] {
    AccountHistoryEntry.merged(
      remote: local ? [] : store.accountHistory.items, local: store.history, accountID: store.owner)
  }
  var body: some View {
    List {
      Picker("来源", selection: $local) {
        Text("账号与本机").tag(false)
        Text("仅本机").tag(true)
      }.pickerStyle(.segmented)
      ForEach(rows) { entry in
        Button {
          store.open(entry.video.bvid, initialCID: entry.cid > 0 ? entry.cid : nil)
        } label: {
          HStack(spacing: 12) {
            Thumbnail(url: entry.video.cover).frame(width: 120, height: 68).clipShape(
              .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 7) {
              Text(entry.video.title).lineLimit(2)
              Text(
                entry.isLocal
                  ? "本机 · \(clock(Double(entry.progress)))"
                  : "账号 · \(clock(Double(max(0,entry.progress))))"
              ).font(.caption).foregroundStyle(.secondary)
            }
          }
        }.buttonStyle(.plain)
      }
      if !local {
        if store.accountHistory.loading { ProgressView() }
        if let error = store.accountHistory.error {
          MobileError(text: error) {
            Task { await store.accountHistory.load(api: store.api, refresh: true) }
          }
        }
        if store.accountHistory.hasMore && !store.accountHistory.loading && store.api.signedIn {
          Button("加载更多记录") { Task { await store.accountHistory.load(api: store.api) } }
        }
      }
      if rows.isEmpty
        && (local || (!store.accountHistory.loading && store.accountHistory.error == nil))
      {
        ContentUnavailableView(
          "暂无观看记录", systemImage: "clock",
          description: Text("播放过的视频会显示在这里。"))
      }
    }.navigationTitle("观看记录").task(id: store.account?.mid) {
      if store.account != nil { await store.accountHistory.loadIfNeeded(api: store.api) }
    }.refreshable {
      if !local && store.account != nil {
        await store.accountHistory.load(api: store.api, refresh: true)
      }
    }
  }
}
struct MobileProfile: View {
  @Bindable var store: Store
  let mid: Int
  @State private var profile: Profile?
  @State private var error: String?
  @State private var changing = false
  @State private var loading = false
  @State private var videos = VideoListModel()
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if let p = profile {
          VStack(spacing: 12) {
            MobileAvatar(url: p.face).frame(width: 76, height: 76)
            Text(p.name).font(.title2.bold()).multilineTextAlignment(.center)
            if !p.bio.isEmpty {
              Text(p.bio).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            HStack(spacing: 16) {
              statistic("关注", count: p.following)
              statistic("粉丝", count: p.fans)
              statistic("投稿", count: p.videos)
            }
            if mid != store.account?.mid {
              Button(p.isFollowed ? "已关注" : "关注") { Task { await follow(p) } }
                .buttonStyle(.glass).disabled(changing)
            }
          }.frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        if loading { ProgressView("正在加载用户资料").frame(maxWidth: .infinity) }
        if let error { MobileError(text: error) { Task { await loadProfile() } } }
        Text("投稿").font(.title3.bold())
        MobileVideoGrid(videos: videos.items, store: store)
        if videos.loading { ProgressView("正在加载投稿").frame(maxWidth: .infinity) }
        if let error = videos.error {
          MobileError(text: error) {
            Task { await loadVideos(reset: videos.items.isEmpty || !videos.hasMore) }
          }
        }
        if !videos.loading && videos.items.isEmpty && videos.error == nil {
          ContentUnavailableView("暂无投稿", systemImage: "play.rectangle")
        }
        if videos.hasMore && !videos.loading && !videos.items.isEmpty {
          Button("加载更多投稿") { Task { await loadVideos() } }
            .buttonStyle(.glass).frame(maxWidth: .infinity)
        }
      }.padding(16)
    }.navigationTitle(profile?.name ?? "个人主页").navigationBarTitleDisplayMode(.inline)
      .task(id: mid) {
        async let header: () = profile == nil ? loadProfile() : ()
        async let feed: () = videos.loadedAt == nil ? loadVideos(reset: true) : ()
        _ = await (header, feed)
      }
      .refreshable {
        async let header: () = loadProfile()
        async let feed: () = loadVideos(reset: true)
        _ = await (header, feed)
      }
  }
  private func statistic(_ title: String, count: Int) -> some View {
    VStack(spacing: 4) {
      Text(compactCount(count)).font(.headline).monospacedDigit()
      Text(title).font(.caption).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity)
  }
  private func loadProfile() async {
    guard !loading else { return }
    loading = true
    error = nil
    defer { loading = false }
    do {
      let result = try await store.api.profile(mid)
      try Task.checkCancellation()
      profile = result
    } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
  }
  private func loadVideos(reset: Bool = false) async {
    await videos.load(reset: reset) { page in try await store.api.profileVideos(mid, page: page) }
  }
  private func follow(_ profile: Profile) async {
    guard store.account != nil else {
      store.login()
      return
    }
    guard !changing else { return }
    changing = true
    error = nil
    defer { changing = false }
    do {
      _ = try await store.api.post(
        "/x/relation/modify",
        ["fid": String(mid), "act": profile.isFollowed ? "2" : "1", "re_src": "11"])
      self.profile?.isFollowed.toggle()
    } catch { self.error = error.localizedDescription }
  }
}
struct MobileSettings: View {
  @AppStorage("interfaceAnimations") private var interfaceAnimations = true
  @Bindable var store: Store
  @AppStorage("appearance") private var appearance = "system"
  @AppStorage("autoPlay") private var autoPlay = true
  @AppStorage("autoPlayParts") private var autoParts = true
  @AppStorage("autoPlayNext") private var autoNext = false
  @AppStorage("backgroundPlayback") private var backgroundPlayback = true
  @AppStorage("rememberPosition") private var remember = true
  @AppStorage("syncWatchHistory") private var sync = true
  @AppStorage("videoThreads") private var threads = 4
  @AppStorage("bufferSeconds") private var buffer = 15.0
  @AppStorage("continuousPreload") private var preload = true
  @AppStorage("preloadDiskGB") private var disk = 8
  @AppStorage("videoCodecPreference") private var codec = "hevc"
  @AppStorage("downloadThreads") private var downloadThreads = 4
  @AppStorage("simultaneousDownloads") private var downloadTasks = 1
  @AppStorage("downloadDanmaku") private var downloadDanmaku = true
  @AppStorage("danmakuEnabled") private var danmaku = true
  @AppStorage("danmakuOpacity") private var opacity = 0.85
  @AppStorage("danmakuScale") private var scale = 1.0
  @AppStorage("danmakuArea") private var area = 0.5
  @State private var clearHistory = false
  @State private var cacheNotice: String?
  var body: some View {
    Form {
      Section("外观") {
        Toggle("界面动画", isOn: $interfaceAnimations)
        Picker("颜色模式", selection: $appearance) {
          Text("跟随系统").tag("system")
          Text("浅色").tag("light")
          Text("深色").tag("dark")
        }
      }
      Section("首页与导航") { BrowsePreferenceFields() }
      Section("播放") {
        Picker("首选编码", selection: $codec) {
          ForEach(VideoCodecPreference.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Text("同一画质优先使用所选编码；没有对应流或播放失败时自动回退。AV1 需要设备硬件支持。下次打开视频或切换画质生效。")
          .font(.caption).foregroundStyle(.secondary)
        Text(VideoCodecPreference.hardwareDecodeSummary + "具体解码方式由系统播放器选择。")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("自动播放", isOn: $autoPlay)
        Toggle("后台播放", isOn: $backgroundPlayback)
          .onChange(of: backgroundPlayback) { store.updateBackgroundPlayback() }
        Toggle("分 P 自动连播", isOn: $autoParts)
        Toggle("合集与播放列表自动连播", isOn: $autoNext)
        Text("分 P 按当前视频顺序播放；最后一 P 结束后，仅在开启合集连播时进入下一个视频。单集循环优先于连播。")
          .font(.caption).foregroundStyle(.secondary)
        Toggle("记住观看位置", isOn: $remember)
        Toggle("同步观看进度到账号", isOn: $sync)
        Stepper("视频加载并发：\(threads)", value: $threads, in: 1...32)
        Text("此值为并发上限。起播及切换画质先使用最多 4 路，出画后按传输情况逐步增加。")
          .font(.caption).foregroundStyle(.secondary)
        VStack(alignment: .leading) {
          Text("前向缓冲：\(Int(buffer)) 秒")
          Slider(value: $buffer, in: 5...120, step: 5)
        }
      }
      Section {
        Toggle("持续预读到片尾", isOn: $preload)
        Stepper("临时缓存上限：\(disk) GB", value: $disk, in: 1...32)
      } header: {
        Text("预读")
      } footer: {
        Text("与电脑版共用 CDN 自动择优、备用源、并发分块、断线恢复与磁盘预读。预读会增加流量和存储占用，新的视频或清晰度生效。")
      }
      Section("下载") {
        Stepper("每个下载的连接数：\(downloadThreads)", value: $downloadThreads, in: 1...32)
        Stepper("同时下载任务：\(downloadTasks)", value: $downloadTasks, in: 1...3)
        Toggle("同时保存弹幕", isOn: $downloadDanmaku)
        Text("并发、分块校验与断点恢复使用电脑版逻辑；当前任务在前台运行，系统挂起后不保证继续。")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("弹幕") {
        Toggle("显示弹幕", isOn: $danmaku)
        VStack(alignment: .leading) {
          Text("不透明度")
          Slider(value: $opacity, in: 0.1...1)
        }
        VStack(alignment: .leading) {
          Text("文字大小")
          Slider(value: $scale, in: 0.5...2)
        }
        VStack(alignment: .leading) {
          Text("显示区域")
          Slider(value: $area, in: 0.2...1)
        }
        NavigationLink("过滤与滚动设置") { MobileDanmakuSettings(presentedAsSheet: false) }
      }
      Section("本机数据") {
        Button("清理封面缓存") {
          Task {
            await ThumbnailCache.shared.clear()
            cacheNotice = "已清理封面缓存"
          }
        }
        Button("清空本机观看记录", role: .destructive) { clearHistory = true }
        if let cacheNotice { Text(cacheNotice).foregroundStyle(.secondary) }
      }
      Section("关于") {
        LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0") · iOS 开发预览")
        Text("面向个人学习与研究，与哔哩哔哩官方无任何关联，未获得官方授权或背书。当前为开发预览版本，源码保留 MIT 授权范围。").font(.footnote)
          .foregroundStyle(.secondary)
        Link("项目主页与版本下载", destination: URL(string: "https://github.com/wzk112/Bilibili-NEXT")!)
        NavigationLink("更新日志") { MobileChangelog() }
        NavigationLink("开源许可") {
          ScrollView {
            Text(licenses).font(.caption.monospaced()).textSelection(.enabled).padding()
          }.navigationTitle("开源许可")
        }
      }
    }.navigationTitle("设置").confirmationDialog(
      "清空本机观看记录？", isPresented: $clearHistory, titleVisibility: .visible
    ) {
      Button("清空", role: .destructive) {
        store.history = []
        store.persist()
      }
    } message: {
      Text("不会删除账号历史。")
    }
  }
  private var licenses: String {
    ["LICENSE", "BiliKit-LICENSE", "THIRD_PARTY"].compactMap { name in
      Bundle.main.url(forResource: name, withExtension: name == "THIRD_PARTY" ? "md" : "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }.joined(separator: "\n\n")
  }
}

private struct MobileChangelog: View {
  @State private var lines: [String] = []
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3))).font(.title3.bold()).padding(.top, 12)
          } else if line.hasPrefix("# ") {
            Text(String(line.dropFirst(2))).font(.title.bold())
          } else if line.hasPrefix("- ") {
            HStack(alignment: .top, spacing: 8) { Text("•"); Text(String(line.dropFirst(2))) }
          } else if !line.isEmpty { Text(line).foregroundStyle(.secondary) }
        }
      }.frame(maxWidth: 840, alignment: .leading).padding(20).frame(maxWidth: .infinity)
        .textSelection(.enabled)
    }.navigationTitle("更新日志").navigationBarTitleDisplayMode(.inline)
      .task {
        let text = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
          .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "暂时无法读取更新日志。"
        lines = text.components(separatedBy: .newlines)
      }
  }
}
