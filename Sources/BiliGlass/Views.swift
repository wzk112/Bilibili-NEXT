import AVKit
import SwiftUI

let biliPink = Color(red: 0.86, green: 0.24, blue: 0.43)
struct RootView: View {
  @Bindable var store: Store
  @Environment(\.scenePhase) private var phase
  @FocusState private var searchFocused: Bool
  @AppStorage("macSidebarVisible") private var sidebarVisible = true
  private var navigation = NavigationCustomization()
  @State private var diagnosticChallenge: InteractionChallenge?
  var body: some View {
    ZStack {
      if !store.fullscreen.isPresented { GlassBackdrop() }
      GeometryReader { viewport in
      HStack(alignment: .top, spacing: 14) {
        if sidebarVisible {
          sidebar.frame(width: AppLayout.sidebarWidth).sidebarTransition()
        }
        VStack(spacing: 12) {
          GlassEffectContainer { topbar }
          if let reason = store.loginUpgradeReason, !store.loginUpgradeDismissed {
            HStack(spacing: 12) {
              Image(systemName: "person.crop.circle.badge.exclamationmark")
              Text(reason.message).font(.callout).fixedSize(horizontal: false, vertical: true)
              Spacer(minLength: 0)
              Button("重新登录") { store.login() }.buttonStyle(.glassProminent)
              Button("稍后") { store.loginUpgradeDismissed = true }.buttonStyle(.glass)
            }.padding(14).floatingGlass(18)
          }
          if searchFocused && !store.showPlayer { SearchAssistance(store: store) }
          content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }.interfaceAnimation(sidebarVisible)
        .padding(.horizontal, 16).padding(.bottom, 16).padding(.top, 16)
        .opacity(store.fullscreen.isPresented ? 0 : 1)
        .allowsHitTesting(!store.fullscreen.isPresented)
        .accessibilityHidden(store.fullscreen.isPresented)
      }
      if store.fullscreen.isPresented {
        FullscreenPlayerContent(store: store, close: { store.fullscreen.close() }).ignoresSafeArea()
      }
    }
    .overlay(alignment: .bottomTrailing) {
      ZStack(alignment: .bottomTrailing) {
        if store.showsMiniPlayer {
          MiniPlayer(store: store).padding(24).interfaceTransition(mini: true)
        }
      }.interfaceAnimation(store.showsMiniPlayer)
    }
    .tint(biliPink).appAppearance().frame(minWidth: 1020, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
    .background { InitialWindowFocus().frame(width: 0, height: 0) }
    .containerBackground(.black, for: .window)
    .sheet(item: $store.imageGallery) { ImageGallery(target: $0) }
    .sheet(item: $diagnosticChallenge) { challenge in
      VStack {
        HStack { Text("官方验证").font(.headline); Spacer(); Button("关闭") { diagnosticChallenge = nil } }.padding(16)
        OfficialChallengeView(api: store.api, challenge: challenge) {
          diagnosticChallenge = nil
          let args = ProcessInfo.processInfo.arguments
          if let i = args.firstIndex(of: "--full-coin-check"), args.indices.contains(i + 2) {
            Task { await Diagnostics.fullCoinCheck(api: store.api, bvid: args[i + 1],
              output: URL(fileURLWithPath: args[i + 2]).appendingPathExtension("verified.json")) }
          }
        }
      }.frame(width: 640, height: 560)
    }
    .sheet(item: $store.reportTarget) { VideoReportForm(store: store, video: $0) }
    .confirmationDialog("拉黑这个 UP 主？", isPresented: Binding(get: { store.blockTarget != nil }, set: { if !$0 { store.blockTarget = nil } }), titleVisibility: .visible, presenting: store.blockTarget) { video in
      Button("拉黑", role: .destructive) { Task { await store.blockAuthor(video) }; store.blockTarget = nil }
    }
    .sheet(item: $store.webTarget) { target in
      VStack(spacing: 0) {
        HStack {
          Spacer()
          Button("完成") { store.webTarget = nil }
        }.padding(12)
        OfficialWebPanel(target: target, api: store.api)
      }.frame(minWidth: 1000, minHeight: 720)
    }
    .sheet(item: $store.profileTarget) { target in
      VStack {
        HStack {
          Spacer()
          Button("关闭") { store.profileTarget = nil }
        }.padding()
        ProfilePage(store: store, mid: target.id).padding(.horizontal, 16).padding(.bottom, 16)
      }.frame(minWidth: 900, minHeight: 650).background { GlassBackdrop() }
    }
    .overlay(alignment: .bottom) {
      if let text = store.interactionMessage {
        HStack {
          Text(text)
          Button {
            store.interactionMessage = nil
          } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain)
        }.padding(14).glassEffect(.regular, in: .capsule).padding(20)
      }
    }
    .sheet(isPresented: $store.showLogin, onDismiss: { store.closeLogin() }) {
      LoginSheet(store: store)
    }
    .task {
      #if DEBUG
        if let url = LocalPlaybackFixture.url {
          LocalPlaybackFixture.prepare(store: store, url: url)
          return
        }
      #endif
      await store.start()
      let args = ProcessInfo.processInfo.arguments
      if let i = args.firstIndex(of: "--full-coin-check"), args.indices.contains(i + 2) {
        await Diagnostics.fullCoinCheck(api: store.api, bvid: args[i + 1], output: URL(fileURLWithPath: args[i + 2]),
          showChallenge: args.contains("--show-coin-challenge") ? { diagnosticChallenge = $0 } : nil)
      }
      if let i = args.firstIndex(of: "--message-read-checks"), args.indices.contains(i + 1) { await Diagnostics.messageReadCheck(store: store, output: URL(fileURLWithPath: args[i + 1])) }
      if let i = args.firstIndex(of: "--feature-read-checks"), args.indices.contains(i + 1) { await Diagnostics.featureReadChecks(store: store, output: URL(fileURLWithPath: args[i + 1])) }
      if let i = args.firstIndex(of: "--preview-read-check"), args.indices.contains(i + 2) { await Diagnostics.previewReadCheck(api: store.api, bvid: args[i + 1], output: URL(fileURLWithPath: args[i + 2])) }
      if let i = args.firstIndex(of: "--special-diagnostics"), args.indices.contains(i + 2) {
        await Diagnostics.special(store: store, output: URL(fileURLWithPath: args[i + 1]), bvid: args[i + 2])
      }
      if let i = args.firstIndex(of: "--native-diagnostics"), args.indices.contains(i + 1) {
        await Diagnostics.nativeFeatures(store: store, output: URL(fileURLWithPath: args[i + 1]))
      }
      if let i = args.firstIndex(of: "--community-diagnostics"), args.indices.contains(i + 1) {
        await Diagnostics.community(store: store, output: URL(fileURLWithPath: args[i + 1]))
      }
      if let i = args.firstIndex(of: "--video-diagnostics"), args.indices.contains(i + 2) {
        await Diagnostics.run(
          store: store, output: URL(fileURLWithPath: args[i + 1]), bvids: [args[i + 2]])
      }
      if let i = args.firstIndex(of: "--diagnostics"), args.indices.contains(i + 1) {
        await Diagnostics.run(store: store, output: URL(fileURLWithPath: args[i + 1]))
      }
    }
    .task {
      let args = ProcessInfo.processInfo.arguments
      if let i = args.firstIndex(of: "--state-output"), args.indices.contains(i + 1) {
        await Diagnostics.state(store: store, output: URL(fileURLWithPath: args[i + 1]))
      }
    }
    .task(id: "\(phase):\(store.api.authenticationGeneration):\(store.account?.mid ?? 0)") {
      guard store.account != nil else { store.messageUnread.reset(); return }
      guard phase == .active else { return }
      await store.messageUnread.poll(api: store.api)
    }
    .onDisappear {
      store.playback.stop()
      store.danmaku.stop()
      store.comments.stop()
      #if DEBUG
        if LocalPlaybackFixture.url == nil { store.downloads.persist() }
      #else
        store.downloads.persist()
      #endif
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
      store.playback.saveCurrentProgress()
    }
    .onChange(of: store.searchFocus) { searchFocused = true }
    .onChange(of: store.playerFocus) { searchFocused = false; store.playback.focusPlayer() }
    .onChange(of: store.navigationRevision) {
      if !store.showPlayer { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
    }
  }
  private var sidebar: some View {
    VStack(spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "play.rectangle.fill").font(.title2).foregroundStyle(biliPink)
        Text("Bilibili NEXT").font(.title3.weight(.semibold))
        Spacer(minLength: 0)
        SettingsLink { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).help("设置")
      }.padding(.horizontal, 18).frame(height: AppLayout.toolbarHeight).floatingGlass(AppLayout.panelRadius)
        .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        // Glass sampling must stay inside the scrolling viewport. Sharing a
        // container with the fixed account footer lets the scrolled glass/text
        // render through that footer on short windows.
        GlassEffectContainer(spacing: 16) {
          VStack(spacing: 14) {
            let pages = navigation.preferences.visible
            let browse = pages.filter(\.isBrowse).compactMap { Destination(rawValue: $0.title) }
            let library = pages.filter { !$0.isBrowse }.compactMap { Destination(rawValue: $0.title) }
            if !browse.isEmpty { navigationGroup("浏览", items: browse) }
            if !library.isEmpty { navigationGroup("资料库", items: library) }
          }.padding(2)
        }
      }.frame(minHeight: 0, maxHeight: .infinity)
        .scrollIndicators(.hidden).compositingGroup().clipped()
      accountButton.fixedSize(horizontal: false, vertical: true)
    }.frame(maxHeight: .infinity)
  }
  private func navigationGroup(_ title: String, items: [Destination]) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 12)
        .padding(.bottom, 8)
      ForEach(items) { d in
        Button {
          store.navigate(d)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: d.icon).frame(width: 20)
            Text(d.rawValue)
            Spacer(minLength: 0)
            if d == .messages { MessageUnreadBadge(count: store.messageUnread.counts.total) }
            if d == .downloads && store.downloads.activeCount > 0 {
              Text("\(store.downloads.activeCount)").font(.caption.monospacedDigit())
            }
          }.font(
            .system(
              size: 14, weight: store.destination == d && !store.showPlayer ? .semibold : .regular)
          )
          .padding(.horizontal, 12).padding(.vertical, 11).contentShape(
            RoundedRectangle(cornerRadius: 12)
          )
          .background(
            store.destination == d && !store.showPlayer ? biliPink.opacity(0.19) : .clear,
            in: .rect(cornerRadius: 12)
          )
          .foregroundStyle(.primary)
        }.buttonStyle(NavigationButtonStyle()).tint(.primary)
      }
    }.padding(10).floatingGlass(20)
  }
  private var topbar: some View {
    HStack(spacing: 10) {
      Button { sidebarVisible.toggle() } label: {
        Image(systemName: "sidebar.left")
      }.help(sidebarVisible ? "隐藏侧栏" : "显示侧栏")
        .accessibilityLabel(sidebarVisible ? "隐藏侧栏" : "显示侧栏")
        .accessibilityIdentifier("toggle-sidebar")
      if !sidebarVisible {
        Menu {
          ForEach(navigation.preferences.visible) { page in
            if let destination = Destination(rawValue: page.title) {
              Button { store.navigate(destination) } label: {
                Label(page.title, systemImage: page.symbol)
              }
            }
          }
          Divider()
          if store.account == nil {
            Button("登录") { store.login() }.disabled(store.restoring)
          } else {
            Button("我的主页") { store.navigate(.profile) }
            Button("重新登录") { store.login() }
            Button("退出登录", role: .destructive) { store.logout() }
          }
        } label: {
          Image(systemName: "list.bullet")
        }.help("导航与账户").accessibilityLabel("导航与账户")
      }
      if store.showPlayer {
        Button {
          store.leavePlayer()
        } label: {
          Image(systemName: "chevron.left")
        }.buttonStyle(.glass).help("返回")
      }
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索视频或粘贴 BV 号", text: $store.query).focused($searchFocused).textFieldStyle(.plain)
          .onSubmit { store.search() }
          .onExitCommand { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
        if !store.query.isEmpty {
          Button {
            store.clearSearch()
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }.buttonStyle(.plain).help("清除搜索")
        }
      }.padding(.horizontal, 12).frame(maxWidth: 520).frame(height: 36)
        .background(.primary.opacity(0.06), in: .capsule)
      Spacer(minLength: 0)
      SettingsLink { Image(systemName: "gearshape") }.help("设置")
      Button {
        if store.showPlayer { store.playback.retry(api: store.api) } else { store.reload() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }.help("刷新")
    }.buttonStyle(.glass).tint(.primary).padding(.horizontal, 12).frame(height: AppLayout.toolbarHeight)
      .floatingGlass(AppLayout.panelRadius).interfaceAnimation(sidebarVisible)
  }
  @ViewBuilder private var content: some View {
    ZStack {
      browsingContent.id(store.destination).clipShape(.rect(cornerRadius: 24))
        .interfaceTransition().opacity(store.showPlayer ? 0 : 1)
        .allowsHitTesting(!store.showPlayer).accessibilityHidden(store.showPlayer)
      if store.showPlayer { PlayerPage(store: store).transition(.opacity) }
    }
    .interfaceAnimation(store.showPlayer)
    .interfaceAnimation(store.destination)
    .onChange(of: navigation.preferences) { normalizeDestination() }
  }
  private func normalizeDestination() {
    if let page = StartPage.allCases.first(where: { $0.title == store.destination.rawValue }),
       !navigation.preferences.allows(page) {
      store.navigate(Destination(rawValue: navigation.preferences.resolvedStart.title) ?? .profile)
    }
  }
  @ViewBuilder private var browsingContent: some View {
      switch store.destination {
      case .recommend, .popular, .regions, .favorites, .later: browse
      case .dynamic: NativeDynamicsPage(store: store)
      case .profile:
        if let account = store.account {
          ProfilePage(store: store, mid: account.mid)
        } else {
          ContentUnavailableView {
            Label("登录后查看主页", systemImage: "person.crop.circle")
          } actions: {
            Button("登录") { store.login() }
          }
        }
      case .history: HistoryPage(store: store)
      case .downloads: DownloadPage(store: store)
      case .messages: NativeInboxPage(store: store)
      case .web: WebFunctionsPage(store: store)
      }
  }
  private var accountButton: some View {
    Group {
      if let account = store.account {
        HStack(spacing: 10) {
          Button {
            store.navigate(.profile)
          } label: {
            HStack(spacing: 10) {
              Thumbnail(url: account.face, mode: .fill, placeholder: "person.crop.circle.fill")
                .frame(width: 32, height: 32).clipShape(
                  Circle())
              Text(account.name).lineLimit(1)
              Spacer(minLength: 0)
            }.contentShape(Rectangle())
          }.buttonStyle(.plain)
          Menu {
            Button("我的主页") { store.navigate(.profile) }
            SettingsLink { Text("设置") }
            Button("重新登录") { store.login() }
            Button("退出登录", role: .destructive) { store.logout() }
          } label: {
            Image(systemName: "ellipsis")
          }
          .menuStyle(.borderlessButton).frame(width: 20)
        }.padding(12).frame(height: 58)
      } else if store.restoring {
        HStack {
          ProgressView().controlSize(.small)
          Text("恢复登录中").font(.callout)
        }.padding(10)
      } else {
        Button {
          store.login()
        } label: {
          HStack {
            Image(systemName: "person.crop.circle").font(.title2)
            Text("登录")
            Spacer()
            Image(systemName: "qrcode").foregroundStyle(.secondary)
          }.padding(10).frame(maxWidth: .infinity).contentShape(.rect(cornerRadius: 20))
        }.buttonStyle(.plain)
      }
    }.frame(maxWidth: .infinity).frame(height: 58).floatingGlass(20)
  }
  private var browse: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline) {
          Text(store.activeQuery.isEmpty ? store.destination.rawValue : "搜索结果").font(AppLayout.pageTitle)
          if !store.activeQuery.isEmpty { Text(store.activeQuery).foregroundStyle(.secondary) }
          Spacer()
          if store.busy { ProgressView().controlSize(.small) }
        }
        if !store.activeQuery.isEmpty { SearchFilters(store: store) }
        if store.destination == .regions && store.activeQuery.isEmpty { RegionSelector(store: store) }
        if [.favorites, .later].contains(store.destination) && store.activeQuery.isEmpty { LibraryToolbar(store: store) }
        if store.destination == .favorites && !store.folders.isEmpty {
          Picker("收藏夹", selection: $store.selectedFolder) {
            ForEach(store.folders) { f in Text(f.title + "（\(f.count)）").tag(f.id) }
          }.pickerStyle(.menu).onChange(of: store.selectedFolder) {
            store.videos = []
            store.reload()
          }
        }
        if let error = store.error, store.videos.isEmpty { ErrorBanner(text: error) { store.reload() } }
        if store.videos.isEmpty && store.searchUsers.isEmpty && !store.busy && !store.restoring && store.error == nil {
          ContentUnavailableView(
            "没有找到视频", systemImage: "magnifyingglass", description: Text("换个关键词试试"))
        }
        if !store.activeQuery.isEmpty && store.searchOptions.users { SearchUserResults(store: store) } else {
          videoGrid(store.destination == .later && !store.libraryQuery.isEmpty ? store.videos.filter { $0.title.localizedCaseInsensitiveContains(store.libraryQuery) || $0.author.localizedCaseInsensitiveContains(store.libraryQuery) } : store.videos)
        }
        if !store.videos.isEmpty || (!store.activeQuery.isEmpty && !store.searchUsers.isEmpty) {
          LoadMoreFooter(loading: store.busy, hasMore: store.hasMore, error: store.error, count: store.videos.count + store.searchUsers.count) { store.more() }
        }
      }.padding(AppLayout.pageInset).padding(.vertical, 8)
    }.modifier(RememberedScroll(memory: store.browsePosition, tracking: !store.showPlayer && !store.busy))
      .id(store.browseKey)
      .accessibilityIdentifier("browse-list")
      .overlay { if store.busy && store.videos.isEmpty { ProgressView("正在加载") } }
  }
  private func videoGrid(_ videos: [Video]) -> some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 14)], alignment: .leading,
      spacing: 18
    ) {
      ForEach(videos.filter { !store.blockedAuthors.contains($0.ownerID ?? 0) }) { video in
        Button {
          store.openFeedVideo(video)
        } label: {
          VideoCard(video: video)
        }.buttonStyle(InterfacePressStyle()).contextMenu {
          Button("播放") { store.open(video.bvid) }
          Button("稍后再看") { Task { do { let aid = try await store.api.videoAid(video); await store.addLater(aid) } catch { store.interactionMessage = error.localizedDescription } } }
          if store.destination == .later { Button("从稍后再看移除") { Task { do { try await store.api.removeWatchLater(video); store.reload() } catch { store.interactionMessage = error.localizedDescription } } } }
          Button("复制链接") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
              "https://www.bilibili.com/video/\(video.bvid)", forType: .string)
          }
          Link("在浏览器打开", destination: URL(string: "https://www.bilibili.com/video/\(video.bvid)")!)
          VideoContextActions(store: store, video: video)
        }
      }
    }
  }
}
struct VideoCard: View {
  let video: Video
  var showsViews = true
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Thumbnail(url: video.cover, mode: .fill).aspectRatio(16 / 9, contentMode: .fit).clipShape(
        RoundedRectangle(cornerRadius: 12)
      ).overlay(alignment: .bottom) {
        HStack(spacing: 8) {
          if showsViews {
            Label(video.views.formatted(.number.notation(.compactName).locale(Locale(identifier: "zh_CN"))), systemImage: "play.fill")
              .accessibilityLabel("播放量 \(video.views)")
          }
          Spacer(minLength: 4)
          Text(duration(video.duration)).monospacedDigit()
        }.font(.caption).foregroundStyle(.white).padding(8)
          .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
              .padding(.top, -12)
          }
      }.clipShape(.rect(cornerRadius: 12))
        .help(showsViews ? "\(video.views.formatted()) 次播放" : "")
      Text(video.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 38, alignment: .topLeading).foregroundStyle(.primary)
      HStack(spacing: 8) {
        Text(video.author).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 2)
        if let date = video.publishedAt {
          Text(date, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
            .fixedSize().help("发布时间 · " + date.formatted(AppDateFormat.timestamp))
        }
      }.font(.caption).foregroundStyle(.secondary)
    }.padding(8).background(.primary.opacity(0.035), in: .rect(cornerRadius: 18))
      .contentShape(.rect(cornerRadius: 18)).cardHover()
  }
  private func duration(_ t: Int) -> String {
    t >= 3600
      ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
      : String(format: "%d:%02d", t / 60, t % 60)
  }
}
struct Thumbnail: View {
  let url: String
  let mode: ContentMode
  var placeholder = "play.rectangle"
  @State private var image: NSImage?
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    GeometryReader { g in
      Group {
        if let image {
          Image(nsImage: image).resizable().aspectRatio(contentMode: mode)
        } else {
          Rectangle().fill(.quaternary).overlay {
            Image(systemName: placeholder).font(.title).foregroundStyle(.tertiary)
          }
        }
      }.frame(width: g.size.width, height: g.size.height).clipped()
      .task(id: "\(url)|\(ThumbnailCache.pixelSize(Int(max(g.size.width, g.size.height) * displayScale)))") {
      image = nil
      let value =
        url.hasPrefix("//")
        ? "https:" + url : url.replacingOccurrences(of: "http://", with: "https://")
      guard let target = URL(string: value),
        let decoded = try? await ThumbnailCache.shared.thumbnail(target, maxPixelSize: Int(max(g.size.width, g.size.height) * displayScale)), !Task.isCancelled
      else { return }
      image = NSImage(cgImage: decoded, size: .zero)
    }
    }.onDisappear { image = nil }
  }
}
struct ErrorBanner: View {
  let text: String
  let retry: () -> Void
  var body: some View {
    HStack {
      Image(systemName: "exclamationmark.circle")
      Text(text).textSelection(.enabled)
      Spacer()
      Button("重试", action: retry)
    }.padding(16).floatingGlass(18)
  }
}
struct ScrollingVideoTitle: View {
  let title: String
  @AppStorage("interfaceAnimations") private var animations = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var position = ScrollPosition(x: 0)
  @State private var textWidth: CGFloat = 0
  @State private var viewportWidth: CGFloat = 0
  @State private var hovering = false
  private struct ScrollRequest: Equatable {
    let title: String
    let overflow: CGFloat
    let active: Bool
  }
  var body: some View {
    let overflow = max(0, textWidth - viewportWidth)
    ScrollView(.horizontal) {
      Text(title).font(.title2.weight(.semibold)).lineLimit(1).fixedSize()
        .textSelection(.enabled).accessibilityIdentifier("player-video-title")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
    }
    .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    .scrollPosition($position).frame(height: 28)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
    .onHover { hovering = $0 }
    .accessibilityHint(overflow > 1 ? "可横向滚动查看完整标题" : "")
    .task(id: ScrollRequest(title: title, overflow: overflow,
      active: hovering && animations && !reduceMotion)) {
      position.scrollTo(x: 0)
      guard hovering, animations, !reduceMotion, overflow > 1 else { return }
      do {
        try await Task.sleep(for: .milliseconds(700))
        try Task.checkCancellation()
        withAnimation(.linear(duration: max(2, Double(overflow) / 45))) {
          position.scrollTo(x: overflow)
        }
      } catch { }
    }
  }
}

struct PlayerPage: View {
  @Bindable var store: Store
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var scrollPosition = ScrollPosition(idType: Int.self)
  @State private var videoAboveViewport = false
  @State private var dismissedScrollMiniPlayer = false
  @State private var metadataWidth: CGFloat = 0
  @State private var expandedActionsWidth: CGFloat = 0
  @State private var compactActionsWidth: CGFloat = 0
  @State private var offlineDanmakuManager = false

  private var usesScrollMiniPlayer: Bool {
    videoAboveViewport && !store.playback.pictureInPicture.isPresented
  }

  private var showsScrollMiniPlayer: Bool {
    store.isPlaybackOpen && usesScrollMiniPlayer && !dismissedScrollMiniPlayer && !store.fullscreen.isPresented
  }

  var body: some View {
    @Bindable var p = store.playback
    GeometryReader { viewport in
    let availableWidth = max(0, min(viewport.size.width, 1280) - 32)
    let compactPlaybackControls = availableWidth < 900
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if let detail = p.detail { header(detail) }
        InlinePlaybackSurface(store: store, isInlineVisible: !usesScrollMiniPlayer,
          controlsScrollMiniPlayer: showsScrollMiniPlayer, usesCompactControls: compactPlaybackControls)
          .frame(height: max(240, min((min(viewport.size.width, 1280) - 32) * 9 / 16, viewport.size.height - 250)))
          .onGeometryChange(for: Bool.self) { proxy in
            proxy.frame(in: .scrollView(axis: .vertical)).maxY <= 0
          } action: { aboveViewport in
            videoAboveViewport = aboveViewport
            if !aboveViewport { dismissedScrollMiniPlayer = false }
          }
        if let detail = p.detail, detail.aid > 0 { DanmakuComposer(store: store, aid: detail.aid) }
        if let error = p.error {
          VStack(alignment: .leading, spacing: 10) {
            ErrorBanner(text: error) { p.retry(api: store.api) }

          }
        }
        informationToolbar(availableWidth: availableWidth, showsWatchLater: !compactPlaybackControls)
        if let d = p.detail {
          if d.aid > 0 {
            VideoActionBar(store: store, detail: d, showsPlaybackOptions: compactPlaybackControls)
          } else if compactPlaybackControls {
            HStack {
              Spacer(minLength: 0)
              PlaybackOptionsControls(store: store, onShowDanmakuList: { offlineDanmakuManager = true })
            }
          }
          if !d.description.isEmpty {
            Text(d.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
              .lineSpacing(5).padding(.top, 4)
          }
          VideoDiscovery(store: store)
          Divider().padding(.vertical, 8)
          if d.aid > 0 { CommentsView(store: store, aid: d.aid).padding(.top, 8) }
        }
      }.padding(16).frame(width: min(viewport.size.width, 1280)).frame(maxWidth: .infinity)
    }.scrollPosition($scrollPosition, anchor: .top)
      .clipShape(.rect(cornerRadius: AppLayout.panelRadius))
      .floatingGlass(AppLayout.panelRadius)
      .overlay(alignment: .bottomTrailing) {
        if showsScrollMiniPlayer {
          MiniPlayer(store: store, onReturn: {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
              scrollPosition.scrollTo(edge: .top)
            }
          }, onClose: {
            dismissedScrollMiniPlayer = true
            p.pausePlayback()
          }, returnLabel: "回到视频").padding(12)
        }
      }
      .onChange(of: p.detail?.video.bvid) { _, bvid in
        if bvid != nil { dismissedScrollMiniPlayer = false }
      }
      .sheet(isPresented: $offlineDanmakuManager) { DanmakuManagement(store: store) }
      .task(id: p.selectedCID) {
      #if DEBUG
        if LocalPlaybackFixture.url != nil {
          store.danmaku.items = LocalPlaybackFixture.danmaku
          return
        }
      #endif
      if p.isOffline {
        store.danmaku.start(
          cid: p.selectedCID, api: store.api, player: p.player, localSidecar: p.localDanmaku)
      } else {
        store.danmaku.start(
          cid: p.selectedCID, aid: p.detail?.aid ?? 0, api: store.api, player: p.player)
      }
      if let detail = p.detail, !p.isOffline { await store.extras.load(detail: detail, cid: p.selectedCID, api: store.api) }
    }
    }
  }
  @ViewBuilder private func informationToolbar(availableWidth: CGFloat, showsWatchLater: Bool) -> some View {
    let compact = availableWidth < metadataWidth + expandedActionsWidth + 24
    if let detail = store.playback.detail {
      HStack(spacing: 12) {
        metadata(detail.video)
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { metadataWidth = $0 }
        Spacer(minLength: 8)
        // Native menus understand the system label styles. Cross-fade them in
        // place while the enclosing width animates between their measured sizes.
        ZStack(alignment: .trailing) {
          secondaryPlaybackActions(showsWatchLater: showsWatchLater).labelStyle(.titleAndIcon).fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { expandedActionsWidth = $0 }
            .opacity(compact ? 0 : 1).disabled(compact).allowsHitTesting(!compact).accessibilityHidden(compact)
          secondaryPlaybackActions(showsWatchLater: showsWatchLater).labelStyle(.iconOnly).fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { compactActionsWidth = $0 }
            .opacity(compact ? 1 : 0).disabled(!compact).allowsHitTesting(compact).accessibilityHidden(!compact)
        }
        .frame(width: (compact ? compactActionsWidth : expandedActionsWidth) > 0
          ? (compact ? compactActionsWidth : expandedActionsWidth) : nil, alignment: .trailing)
        .clipped()
        .interfaceAnimation(compact)
      }
    } else {
      HStack {
        secondaryPlaybackActions(showsWatchLater: showsWatchLater)
        Spacer(minLength: 0)
      }
    }
  }

  private func secondaryPlaybackActions(showsWatchLater: Bool) -> some View {
    HStack(spacing: 12) {
      if showsWatchLater, let detail = store.playback.detail, detail.aid > 0 {
        WatchLaterButton(store: store, aid: detail.aid)
      }
      PlaybackFeatureControls(store: store)
      downloadMenu
    }.buttonStyle(.glass).controlSize(.regular)
  }

  @ViewBuilder private var downloadMenu: some View {
    let p = store.playback
    if let d = p.detail, p.streams != nil {
      Menu {
        Button("缓存到应用") {
          store.downloads.enqueue(
            video: d.video, cid: p.selectedCID, qn: p.selectedQuality, api: store.api,
            cached: true)
        }
        Button("下载到其他位置…") {
          store.downloads.enqueue(
            video: d.video, cid: p.selectedCID, qn: p.selectedQuality, api: store.api,
            cached: false)
        }
        Divider()
        Button("下载弹幕 XML…") {
          Task {
            await store.downloads.saveDanmaku(
              video: d.video, cid: p.selectedCID, api: store.api)
          }
        }
      } label: {
        Label("下载", systemImage: "arrow.down").foregroundStyle(.primary)
      }.tint(.primary).disabled(p.loading).help("下载")
    }
  }

  private func header(_ detail: Detail) -> some View {
    HStack(spacing: 12) {
      ScrollingVideoTitle(title: detail.video.title).frame(maxWidth: .infinity)
      author(detail).font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: 120, alignment: .trailing).fixedSize(horizontal: true, vertical: false)
    }
  }
  private func author(_ detail: Detail) -> some View {
    Button { store.showProfile(detail.ownerID) } label: {
      Text(detail.video.author).lineLimit(1).truncationMode(.middle).help(detail.video.author)
    }.buttonStyle(.plain).disabled(detail.ownerID <= 0)
  }
  private func metadata(_ video: Video) -> some View {
    HStack(spacing: 12) {
      Label("\(video.views.formatted()) 次播放", systemImage: "play")
      if let date = video.publishedAt {
        Text(date, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
          .help("发布时间 · " + date.formatted(AppDateFormat.timestamp))
          .accessibilityLabel("发布于 " + date.formatted(AppDateFormat.timestamp))
      }
      Text(video.bvid).textSelection(.enabled)
    }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
  }
}
#if DEBUG
/// Explicit local-only preview: no login restoration, remote metadata or history writes.
@MainActor private enum LocalPlaybackFixture {
  static var url: URL? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let index = arguments.firstIndex(of: "--local-playback-fixture"),
      arguments.indices.contains(index + 1) else { return nil }
    return URL(fileURLWithPath: arguments[index + 1])
  }
  static func prepare(store: Store, url: URL) {
    store.playback.onProgress = nil
    store.playback.onEnded = nil
    store.history = []
    store.restoring = false
    store.busy = false
    store.hasMore = false
    store.destination = .recommend
    let video = Video(bvid: "LOCAL-PREVIEW", title: "本地播放与界面检查 · 长标题、发布日期及播放信息", cover: "",
      author: "本地测试素材", duration: 90, views: 123456, publishedAt: Date(timeIntervalSince1970: 1793491200))
    store.playback.openLocal(url, video: video)
    store.isPlaybackOpen = true
    store.showPlayer = true
    store.playerFocus += 1
  }
  static var danmaku: [Danmaku] {
    (0..<180).map { (index: Int) -> Danmaku in
      let mode: Int = index % 19 == 0 ? 5 : (index % 23 == 0 ? 4 : 1)
      let color: Int = index % 5 == 0 ? 0x66DDFF : 0xFFFFFF
      let text: String = index.isMultiple(of: 3) ? "本地滚动弹幕 · 暂停、全屏与字号检查 \(index)" : "中文弹幕清晰度 \(index)"
      return Danmaku(id: "local-preview-\(index)", time: Double(index) * 0.5,
        mode: mode, size: 25, color: color, text: text)
    }
  }
}
#endif
struct LoginSheet: View {
  @Bindable var store: Store
  var body: some View {
    VStack(spacing: 20) {
      HStack {
        Text("登录哔哩哔哩").font(.title2.weight(.semibold))
        Spacer()
        Button {
          store.showLogin = false
        } label: {
          Image(systemName: "xmark")
        }.buttonStyle(.glass).help("关闭")
      }
      ZStack {
        RoundedRectangle(cornerRadius: 16).fill(.white)
        if let image = store.qrImage {
          Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(16).opacity(
            store.loginExpired ? 0.15 : 1)
        }
        if store.qrImage == nil && !store.loginExpired { ProgressView() }
        if store.loginExpired { Button("刷新二维码") { store.refreshQR() }.buttonStyle(.glassProminent) }
      }.frame(width: 230, height: 230)
      Text(store.loginStatus).font(.callout).foregroundStyle(.secondary)
      Text("一次扫码即可使用浏览、收藏与投币。登录不会自动投币。")
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Text("登录信息保存在 macOS 钥匙串").font(.caption).foregroundStyle(.tertiary)
    }.padding(28).frame(width: 380).background { GlassBackdrop() }
  }
}
