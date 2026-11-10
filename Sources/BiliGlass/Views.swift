import AVKit
import SwiftUI

let biliPink = Color(red: 0.86, green: 0.24, blue: 0.43)
struct RootView: View {
  @Bindable var store: Store
  @Environment(\.scenePhase) private var phase
  @FocusState private var searchFocused: Bool
  @AppStorage("macSidebarVisible") private var sidebarVisible = true
  @AppStorage("macSidebarCollapseMode") private var sidebarMode = MacSidebarCollapseMode.icons
  private var compactSidebar: Bool { !sidebarVisible && sidebarMode == .icons }
  private var showsSidebar: Bool { sidebarVisible || sidebarMode == .icons }
  private var navigation = NavigationCustomization()
  @State private var diagnosticChallenge: InteractionChallenge?
  @State private var headerLeadingFrame = CGRect.zero
  @State private var headerRefreshFrame = CGRect.zero
  @State private var searchFieldFrame = CGRect.zero
  @State private var searchPanelFrame = CGRect.zero
  var body: some View {
    ZStack {
      if !store.fullscreen.isPresented { GlassBackdrop() }
      GeometryReader { viewport in
      VStack(spacing: 12) {
        AppGlassContainer { topbar }.padding(.leading, 80).padding(.top, AppLayout.mainToolbarTopInset)
        HStack(alignment: .top, spacing: 14) {
          if showsSidebar {
            MacSidebar(store: store, preferences: navigation.preferences, compact: compactSidebar,
              availableHeight: max(0, viewport.size.height - AppLayout.mainHeaderHeight - 28))
              .frame(width: compactSidebar ? 52 : AppLayout.sidebarWidth).sidebarTransition()
          }
          VStack(spacing: 12) {
            if let reason = store.loginUpgradeReason, !store.loginUpgradeDismissed {
              HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                Text(reason.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("重新登录") { store.login() }.buttonStyle(.appGlassProminent)
                Button("稍后") { store.loginUpgradeDismissed = true }.buttonStyle(.appGlassButton)
              }.padding(14).floatingGlass(AppLayout.panelRadius)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }.interfaceAnimation(sidebarVisible).interfaceAnimation(sidebarMode)
        .padding(.horizontal, 16).padding(.bottom, 16)
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
    .overlay(alignment: .topLeading) {
      if !store.fullscreen.isPresented && searchFocused && searchFieldFrame.width > 0 {
        SearchAssistance(store: store) { term in
          store.query = term
          dismissSearch()
          store.search()
        }
        .frame(width: searchFieldFrame.width).fixedSize(horizontal: false, vertical: true)
        .offset(x: searchFieldFrame.minX, y: searchFieldFrame.maxY + 6)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { searchPanelFrame = $0 }
      }
    }
    .ignoresSafeArea(.container, edges: .top)
    .environment(\.coverPreview, store.coverPreview)
    .onChange(of: store.showPlayer) { if store.showPlayer { store.coverPreview.stop() } }
    .onChange(of: store.navigationRevision) { store.coverPreview.stop() }
    .onChange(of: store.api.authenticationGeneration) { store.coverPreview.stop() }
    .onChange(of: phase) { if phase != .active { searchFocused = false; store.coverPreview.stop() } }
    .tint(biliPink).appAppearance().frame(minWidth: 1020, maxWidth: .infinity, minHeight: 720, maxHeight: .infinity)
    .background { InitialWindowFocus().frame(width: 0, height: 0) }
    .appWindowBackground()
    .background {
      MainWindowChrome(toolbarControls: [headerLeadingFrame, headerRefreshFrame],
        searchRegions: [searchFieldFrame, searchPanelFrame], searchActive: searchFocused,
        dismissSearch: dismissSearch,
        windowInactive: { searchFocused = false; store.coverPreview.stop() }).frame(width: 0, height: 0)
    }
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
          }.buttonStyle(.pointerPlain)
        }.padding(14).appGlassEffect(.regular, in: .capsule).padding(20)
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
      store.coverPreview.stop()
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
    .onChange(of: store.selectedFolder) {
      guard store.destination == .favorites else { return }
      store.videos = []
      store.reload()
    }
    .onChange(of: store.navigationRevision) {
      if !store.showPlayer { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
    }
  }
  private func dismissSearch() {
    searchFocused = false
    NSApp.keyWindow?.makeFirstResponder(nil)
  }
  private var topbar: some View {
    HStack(spacing: 10) {
      HStack(spacing: 10) {
      Button { sidebarVisible.toggle() } label: {
        Image(systemName: "sidebar.left")
      }.help(sidebarVisible ? (sidebarMode == .hidden ? "隐藏侧栏" : "收起侧栏文字") : "展开侧栏")
        .accessibilityLabel(sidebarVisible ? "收起侧栏" : "展开侧栏")
        .accessibilityIdentifier("toggle-sidebar")
      if !showsSidebar {
        MacNavigationMenu(store: store, preferences: navigation.preferences)
      }
      if store.showPlayer {
        Button {
          store.leavePlayer()
        } label: {
          Image(systemName: "chevron.left")
        }.help("返回")
      }
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索视频或粘贴 BV 号", text: $store.query).focused($searchFocused).textFieldStyle(.plain)
          .onSubmit { dismissSearch(); store.search() }
          .onExitCommand { dismissSearch() }
        if !store.query.isEmpty {
          Button {
            store.clearSearch()
          } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
          }.buttonStyle(.pointerPlain).help("清除搜索")
        }
      }.padding(.horizontal, 12).frame(maxWidth: 520).frame(height: 28)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { searchFieldFrame = $0 }
      }.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { headerLeadingFrame = $0 }
      Spacer(minLength: 0)
      Button {
        if store.showPlayer { store.playback.retry(api: store.api) } else { store.reload() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }.help("刷新")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { headerRefreshFrame = $0 }
    }.toolbarButtons().padding(.horizontal, 12).frame(height: AppLayout.mainToolbarHeight)
      .interfaceAnimation(sidebarVisible)
  }
  @ViewBuilder private var content: some View {
    ZStack {
      browsingContent.id(store.destination).clipShape(.rect(cornerRadius: AppLayout.panelRadius))
        .interfaceTransition().opacity(store.showPlayer ? 0 : 1)
        .allowsHitTesting(!store.showPlayer).accessibilityHidden(store.showPlayer)
      if store.showPlayer { PlayerPage(store: store).transition(.opacity) }
    }
    .interfaceAnimation(store.showPlayer)
    .interfaceAnimation(store.destination)
    .onChange(of: navigation.preferences) { normalizeDestination() }
  }
  private func normalizeDestination() {
    if [.messages, .history, .favorites, .later, .downloads, .profile, .web].contains(store.destination) { return }
    if let page = StartPage.allCases.first(where: { $0.title == store.destination.rawValue }),
       !navigation.preferences.allows(page) {
      store.navigate(Destination(rawValue: navigation.preferences.resolvedStart.title) ?? .profile)
    }
  }
  @ViewBuilder private var browsingContent: some View {
      switch store.destination {
      case .recommend, .popular, .regions, .favorites, .later: browse
      case .dynamic: NativeDynamicsPage(store: store)
      case .profile, .web:
        if let account = store.account { ProfilePage(store: store, mid: account.mid) }
        else { GuestAccountPage(store: store) }
      case .history: HistoryPage(store: store)
      case .downloads: DownloadPage(store: store)
      case .messages: NativeInboxPage(store: store)
      case .live: CatalogPage(store: store, kind: .live)
      case .bangumi: CatalogPage(store: store, kind: .bangumi)
      case .cinema: CatalogPage(store: store, kind: .cinema)
      }
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
          }.pickerStyle(.menu)
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
  @Environment(\.coverPreview) private var preview
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Thumbnail(url: video.cover, mode: .fill).aspectRatio(16 / 9, contentMode: .fit).clipShape(
        RoundedRectangle(cornerRadius: AppLayout.mediaRadius)
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
      }.overlay {
        if let preview, preview.activeID == video.bvid {
          CoverPreviewOverlay(preview: preview, token: preview.identity).id(preview.identity)
        }
      }.clipShape(.rect(cornerRadius: AppLayout.mediaRadius))
        .onHover { inside in
          if inside && !reduceMotion { preview?.hover(video) }
          else { preview?.stop(videoID: video.bvid) }
        }
        .onDisappear { preview?.stop(videoID: video.bvid) }
      Text(video.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 38, alignment: .topLeading).foregroundStyle(.primary).help(video.title)
      HStack(spacing: 8) {
        Text(video.author).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 2)
        if let date = video.publishedAt {
          Text(date, format: .dateTime.year().month(.twoDigits).day(.twoDigits))
            .fixedSize().help("发布时间 · " + date.formatted(AppDateFormat.timestamp))
        }
      }.font(.caption).foregroundStyle(.secondary)
    }.padding(AppLayout.pageInset).background(.primary.opacity(0.035), in: .rect(cornerRadius: AppLayout.panelRadius))
      .contentShape(.rect(cornerRadius: AppLayout.panelRadius)).cardHover()
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
    }.padding(16).floatingGlass(AppLayout.panelRadius)
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
    .scrollPosition($position).frame(height: 28).help(title)
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
  @State private var displayedVideoWidth: CGFloat = 0

  private var usesScrollMiniPlayer: Bool {
    videoAboveViewport && !store.playback.pictureInPicture.isPresented
  }

  private var showsScrollMiniPlayer: Bool {
    store.isPlaybackOpen && usesScrollMiniPlayer && !dismissedScrollMiniPlayer && !store.fullscreen.isPresented
  }

  var body: some View {
    @Bindable var p = store.playback
    GeometryReader { viewport in
    let availableWidth = max(0, viewport.size.width - 32)
    let compactPlaybackControls = displayedVideoWidth < 900
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        PlaybackViewportLayout(viewportHeight: viewport.size.height - 32) {
          Group {
            if let detail = p.detail { header(detail) }
            else { Color.clear.frame(height: 28) }
          }
          InlinePlaybackSurface(store: store, isInlineVisible: !usesScrollMiniPlayer,
            controlsScrollMiniPlayer: showsScrollMiniPlayer, usesCompactControls: compactPlaybackControls)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { displayedVideoWidth = $0 }
            .onGeometryChange(for: Bool.self) { proxy in
              proxy.frame(in: .scrollView(axis: .vertical)).maxY <= 0
            } action: { aboveViewport in
              videoAboveViewport = aboveViewport
              if !aboveViewport { dismissedScrollMiniPlayer = false }
            }
          VStack(alignment: .leading, spacing: 14) {
            if let detail = p.detail, detail.aid > 0 { DanmakuComposer(store: store, aid: detail.aid) }
            if let error = p.error {
              ErrorBanner(text: error) { p.retry(api: store.api) }
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
            }
          }
        }
        if let d = p.detail {
          if !d.description.isEmpty {
            Text(d.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
              .lineSpacing(5).padding(.top, 4)
          }
          VideoDiscovery(store: store)
          Divider().padding(.vertical, 8)
          if d.aid > 0 { CommentsView(store: store, aid: d.aid).padding(.top, 8) }
        }
      }.padding(16).frame(width: viewport.size.width)
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
    }.buttonStyle(.appGlassButton).controlSize(.regular)
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
    }.buttonStyle(.pointerPlain).disabled(detail.ownerID <= 0)
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
        }.buttonStyle(.pointerGlass).help("关闭")
      }
      ZStack {
        RoundedRectangle(cornerRadius: 16).fill(.white)
        if let image = store.qrImage {
          Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(16).opacity(
            store.loginExpired ? 0.15 : 1)
        }
        if store.qrImage == nil && !store.loginExpired { ProgressView() }
        if store.loginExpired { Button("刷新二维码") { store.refreshQR() }.buttonStyle(.pointerGlassProminent) }
      }.frame(width: 230, height: 230)
      Text(store.loginStatus).font(.callout).foregroundStyle(.secondary)
      Text("一次扫码即可使用浏览、收藏与投币。登录不会自动投币。")
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
      Text("登录信息保存在 macOS 钥匙串").font(.caption).foregroundStyle(.tertiary)
    }.padding(28).frame(width: 380).background { GlassBackdrop() }
  }
}
