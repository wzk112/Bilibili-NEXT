import ImageIO
import SwiftUI

let biliPink = Color(red: 0.86, green: 0.24, blue: 0.43)
extension View {
  func appGlass(_ radius: CGFloat = 18) -> some View {
    padding(12).background(.regularMaterial, in: .rect(cornerRadius: radius))
  }
}
struct Thumbnail: View {
  let url: String
  var mode: ContentMode = .fill
  var placeholder = "play.rectangle"
  @State private var image: CGImage?
  var body: some View {
    GeometryReader { geometry in
      Group {
        if let image {
          Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: mode)
        } else {
          Rectangle().fill(.quaternary).overlay {
            Image(systemName: placeholder).foregroundStyle(.secondary)
          }
        }
      }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
    }.task(id: url) {
      image = nil
      guard let target = BiliImageURL.parse(url),
        let result = try? await ThumbnailCache.shared.thumbnail(target), !Task.isCancelled
      else { return }
      image = result
    }
  }
}
struct MobileVideoCard: View {
  let video: Video
  @ScaledMetric(relativeTo: .subheadline) private var titleHeight = 38
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Thumbnail(url: video.cover).aspectRatio(16 / 9, contentMode: .fit).clipShape(
        .rect(cornerRadius: 14)
      )
      .overlay(alignment: .bottomTrailing) {
        Text(clock(Double(video.duration))).font(.caption2.monospacedDigit()).padding(5).background(
          .black.opacity(0.7), in: .capsule
        ).foregroundStyle(.white).padding(7)
      }
      Text(video.title).font(.subheadline.weight(.medium)).lineLimit(2).frame(
        maxWidth: .infinity, minHeight: titleHeight, alignment: .topLeading)
      HStack {
        Text(video.author).lineLimit(1)
        if UIDevice.current.userInterfaceIdiom == .pad {
          Spacer(minLength: 4)
          Label(compactCount(video.views), systemImage: "play")
            .lineLimit(1)
        }
      }.font(.caption).foregroundStyle(.secondary)
    }.padding(UIDevice.current.userInterfaceIdiom == .pad ? 12 : 0)
      .background {
        if UIDevice.current.userInterfaceIdiom == .pad {
          RoundedRectangle(cornerRadius: 22).fill(.regularMaterial)
        }
      }.contentShape(Rectangle())
  }
}
func clock(_ raw: Double) -> String {
  let s = raw.isFinite ? Int(max(0, raw)) : 0
  return s >= 3600
    ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    : String(format: "%d:%02d", s / 60, s % 60)
}
struct MobileError: View {
  let text: String
  var retry: (() -> Void)? = nil
  var body: some View {
    VStack(spacing: 12) {
      Label(text, systemImage: "exclamationmark.circle").font(.callout).textSelection(.enabled)
      if let retry { Button("重试", action: retry).buttonStyle(.glass) }
    }.frame(maxWidth: .infinity).padding(20).background(
      .regularMaterial, in: .rect(cornerRadius: 18))
  }
}
@MainActor @Observable final class VideoListModel {
  let scroll = BrowsePosition()
  var returnRevision = 0
  var items: [Video] = []
  var loading = false
  var hasMore = true
  var error: String?
  private var page = 0
  private var generation = UUID()
  private(set) var loadedAt: Date?
  func load(reset: Bool = false, loader: @MainActor (Int) async throws -> [Video]) async {
    if reset {
      generation = UUID()
      loading = false
      hasMore = true
    }
    guard !loading, hasMore else { return }
    let token = generation
    let next = reset ? 1 : page + 1
    loading = true
    error = nil
    defer { if token == generation { loading = false } }
    do {
      let rows = try await loader(next)
      try Task.checkCancellation()
      guard token == generation else { return }
      let unique = Video.deduplicated(rows, excluding: reset ? [] : Set(items.map(\.bvid)))
      if !reset && unique.isEmpty && !rows.isEmpty {
        error = "本页没有新内容，可重新刷新"
        hasMore = false
        return
      }
      items = reset ? unique : items + unique
      if reset { loadedAt = Date(); scroll.reset() }
      page = next
      hasMore = !rows.isEmpty
    } catch {
      if token == generation && !(error is CancellationError) {
        self.error = error.localizedDescription
      }
    }
  }
}
struct MobileVideoGrid: View {
  let videos: [Video]
  @Bindable var store: Store
  @Environment(\.dynamicTypeSize) private var textSize
  @Environment(\.horizontalSizeClass) private var sizeClass
  var body: some View {
    LazyVGrid(
      columns: [
        GridItem(
          .adaptive(
            minimum: textSize.isAccessibilitySize ? 280 : sizeClass == .regular ? 240 : 160,
            maximum: 400), spacing: UIDevice.current.userInterfaceIdiom == .pad ? 18 : 14)
      ], alignment: .leading, spacing: 20
    ) {
      ForEach(videos) { video in
        Button {
          store.open(video.bvid)
        } label: {
          MobileVideoCard(video: video)
        }.buttonStyle(InterfacePressStyle())
          .accessibilityIdentifier("video-card-" + video.bvid)
          .contextMenu {
            Button("播放", systemImage: "play") { store.open(video.bvid) }
            Button("复制链接", systemImage: "link") {
              UIPasteboard.general.string = "https://www.bilibili.com/video/" + video.bvid
            }
            Button("稍后再看", systemImage: "text.badge.plus") {
              Task { await addLater(video, store: store) }
            }
            Link("在官网打开", destination: URL(string: "https://www.bilibili.com/video/" + video.bvid)!)
          }
      }
    }
  }
}
@MainActor func addLater(_ video: Video, store: Store) async {
  guard store.account != nil else {
    store.login()
    return
  }
  do {
    let aid: Int
    if let known = video.aid {
      aid = known
    } else {
      aid = try await store.api.detail(video.bvid).aid
    }
    _ = try await store.api.post("/x/v2/history/toview/add", ["aid": String(aid)])
    store.message = "已加入稍后再看"
  } catch { store.message = error.localizedDescription }
}
struct MobileVideoList: View {
  let title: String
  var refreshOnReturn: Bool
  var showsNavigationTitle: Bool
  @Bindable var store: Store
  let loader: @MainActor (Int) async throws -> [Video]
  @State private var model: VideoListModel
  init(
    title: String, store: Store, model: VideoListModel? = nil, refreshOnReturn: Bool = false,
    showsNavigationTitle: Bool = true,
    loader: @escaping @MainActor (Int) async throws -> [Video]
  ) {
    self.title = title
    self.refreshOnReturn = refreshOnReturn
    self.showsNavigationTitle = showsNavigationTitle
    self.store = store
    self.loader = loader
    _model = State(initialValue: model ?? VideoListModel())
  }
  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        MobileVideoGrid(videos: model.items, store: store)
        if model.loading { ProgressView("正在加载").padding() }
        if let error = model.error {
          MobileError(text: error) {
            Task { await model.load(reset: model.items.isEmpty || !model.hasMore, loader: loader) }
          }
        }
        if model.items.isEmpty && !model.loading && model.error == nil {
          ContentUnavailableView("暂无内容", systemImage: "play.rectangle")
        }
        if !model.items.isEmpty && model.hasMore && !model.loading {
          Button("加载更多") { Task { await model.load(loader: loader) } }.buttonStyle(.glass).padding()
        }
      }.padding(16)
    }.modifier(RememberedScroll(memory: model.scroll, tracking: !store.showPlayer && !model.loading))
      .accessibilityIdentifier("browse-list")
      .modifier(BrowseNavigationTitle(title: title, enabled: showsNavigationTitle))
      .refreshable { await model.load(reset: true, loader: loader) }
      .task(id: store.homeReturnRevision) {
        let refresh = refreshOnReturn && store.isRecommendedVisible && !store.showPlayer
          && UserDefaults.standard.bool(forKey: "refreshHomeOnReturn")
          && model.returnRevision != store.homeReturnRevision
        model.returnRevision = store.homeReturnRevision
        if model.loadedAt == nil || refresh { await model.load(reset: true, loader: loader) }
      }
  }
}
private struct BrowseNavigationTitle: ViewModifier {
  let title: String
  let enabled: Bool
  func body(content: Content) -> some View {
    if enabled { content.navigationTitle(title).navigationBarTitleDisplayMode(.inline) }
    else { content }
  }
}
@MainActor final class MobileHomeFeeds {
  private var models: [String: VideoListModel] = [:]
  private var order: [String] = []
  func model(for key: String) -> VideoListModel {
    order.removeAll { $0 == key }
    order.append(key)
    if let model = models[key] { return model }
    let model = VideoListModel()
    models[key] = model
    while order.count > 8 { models.removeValue(forKey: order.removeFirst()) }
    return model
  }
}
struct MobileRoot: View {
  @Bindable var store: Store
  @State private var windowSize = CGSize.zero
  @State private var selectedTab = BrowsePreferences().resolvedStart.phoneTab
  @State private var initialLibraryPage: StartPage? = BrowsePreferences().resolvedStart.isLibrary ? BrowsePreferences().resolvedStart : nil
  private var navigation = NavigationCustomization()
  @AppStorage("appearance") private var appearance = "system"
  var body: some View {
    GeometryReader { geometry in
      let tablet = UIDevice.current.userInterfaceIdiom == .pad
      let size = windowSize == .zero ? geometry.size : windowSize
      let columns = AdaptiveNavigationLayout.usesColumns(width: size.width, height: size.height, isTablet: tablet)
      Group {
        if !store.credentialsRestored {
          ProgressView("恢复登录中").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if columns {
          MobileTabletRoot(store: store)
        } else {
          phoneTabs.modifier(MobilePlayerAccessory(store: store))
        }
      }
      .modifier(MobileRootPresentation(store: store, columns: columns))
      .environment(\.columnNavigation, columns)
      .onChange(of: columns) { _, value in
        if !value {
          selectedTab = store.browseDestination.phoneTab
          initialLibraryPage = store.browseDestination.isLibrary ? store.browseDestination : nil
        }
      }
    }
    .background(MobileWindowSizeReader { windowSize = $0 })
    .tint(biliPink).preferredColorScheme(
      appearance == "system" ? nil : appearance == "dark" ? .dark : .light
    )
  }
  private func tabTitle(_ tab: Int) -> String {
    switch tab {
    case 0: "首页"
    case 1: "动态"
    case 2: "消息"
    case 3: "资料库"
    default: navigation.preferences.allows(.profile) ? "我的" : "设置"
    }
  }
  private func tabSymbol(_ tab: Int) -> String {
    switch tab {
    case 0: "house"
    case 1: "rectangle.stack"
    case 2: "bubble.left.and.bubble.right"
    case 3: "square.stack"
    default: navigation.preferences.allows(.profile) ? "person.crop.circle" : "gearshape"
    }
  }
  private var phoneTabs: some View {
    TabView(selection: $selectedTab) {
      ForEach(navigation.preferences.phoneTabs, id: \.self) { tab in
        Tab(tabTitle(tab), systemImage: tabSymbol(tab), value: tab) {
          NavigationStack {
            switch tab {
            case 0: MobileHome(store: store)
            case 1: MobileDynamics(store: store)
            case 2: MobileInbox(store: store)
            case 3:
              MobileLibrary(store: store)
                .navigationDestination(item: $initialLibraryPage) { MobileLibraryDestination(store: store, page: $0) }
            default:
              if navigation.preferences.allows(.profile) { MobileAccount(store: store) }
              else { MobileSettings(store: store) }
            }
          }
        }.badge(tab == 2 ? store.messageUnread.counts.total : 0)
      }
    }
    .onChange(of: navigation.preferences) {
      if !navigation.preferences.phoneTabs.contains(selectedTab) { selectedTab = navigation.preferences.resolvedStart.phoneTab }
      if let page = initialLibraryPage, !navigation.preferences.allows(page) { initialLibraryPage = nil }
      store.isRecommendedVisible = selectedTab == 0 && store.phoneHomeTab == 0
    }
    .onChange(of: selectedTab) { old, value in
      store.isRecommendedVisible = value == 0 && store.phoneHomeTab == 0
      store.browseDestination = value == 0 ? (store.phoneHomeTab == 0 ? .recommend : store.phoneHomeTab == 1 ? .popular : .regions) : value == 1 ? .dynamic : value == 2 ? .messages : value == 3 ? .history : .profile
      if old != 0 && value == 0 { store.homeReturnRevision += 1 }
    }
    .onAppear {
      store.isRecommendedVisible = selectedTab == 0 && store.phoneHomeTab == 0
      #if DEBUG
        if MobileUIFixture.enabled && ProcessInfo.processInfo.arguments.contains("--qa-inbox") {
          selectedTab = 2
        }
      #endif
    }

  }
}
private struct MobileRootPresentation: ViewModifier {
  @Bindable var store: Store
  let columns: Bool
  func body(content: Content) -> some View {
    content
      .fullScreenCover(
        isPresented: Binding(
          get: {
            !columns && store.showPlayer
              && !store.conversationPresented
          },
          set: { if !columns && !store.conversationPresented { store.showPlayer = $0 } }),
        onDismiss: { store.playback.saveCurrentProgress() }
      ) {
        MobilePlayerPage(store: store)
      }
      .sheet(
        isPresented: Binding(
          get: { store.showLogin && !store.showPlayer && !store.conversationPresented },
          set: { store.showLogin = $0 }),
        onDismiss: { store.closeLogin() }
      ) { MobileLogin(store: store) }
      .sheet(
        item: Binding(
          get: { store.showPlayer || store.conversationPresented ? nil : store.webTarget },
          set: { store.webTarget = $0 })
      ) { target in MobileWebPage(store: store, target: target) }
      .alert(
        "提示",
        isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })
      ) {
        Button("好", role: .cancel) { store.message = nil }
      } message: {
        Text(store.message ?? "")
      }
  }
}
struct MobileHome: View {
  @Bindable var store: Store
  var destination: Int? = nil
  @State private var tab: Int
  init(store: Store, destination: Int? = nil) {
    self.store = store
    self.destination = destination
    _tab = State(initialValue: store.phoneHomeTab)
  }
  private var navigation = NavigationCustomization()
  var body: some View {
    let tab = destination ?? tab
    let region = store.homeRegion
    let title = tab == 0 ? "推荐" : tab == 1 ? "热门" : "分区"
    VStack(spacing: 0) {
      if destination != nil {
        Text(title).font(.largeTitle.bold())
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 20).padding(.vertical, 16)
          .accessibilityAddTraits(.isHeader).accessibilityIdentifier("tablet-page-heading")
      }
      if destination == nil {
        Picker("浏览", selection: $tab) {
          ForEach(navigation.preferences.visible.filter(\.isHome)) { page in
            Text(page.title).tag(page == .recommend ? 0 : page == .popular ? 1 : 2)
          }
        }.pickerStyle(.segmented).frame(maxWidth: 640)
          .padding(.horizontal).padding(.bottom, 10).frame(maxWidth: .infinity)
      }
      if tab == 2 {
        Picker("分区", selection: $store.homeRegion) { ForEach(VideoRegion.all) { Text($0.title).tag($0.id) } }
          .pickerStyle(.menu).padding(.horizontal)
      }
      ZStack {
        MobileVideoList(
          title: tab == 0 ? "推荐" : tab == 1 ? "热门" : "分区", store: store,
          model: store.homeFeeds.model(for: "\(tab):\(tab == 2 ? region : 0):\(store.account?.mid ?? 0)"),
          refreshOnReturn: tab == 0, showsNavigationTitle: false
        ) { page in
          if tab == 0 { return try await store.api.recommendations(page: page) }
          if tab == 1 { return try await store.api.popular(page: page) }
          return try await store.api.regionVideos(region, page: page)
        }.id("\(tab):\(region):\(store.account?.mid ?? 0)").interfaceTransition()
      }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        .interfaceAnimation(tab).interfaceAnimation(region)
    }.navigationTitle(destination == nil ? "Bilibili NEXT" : title)
    .navigationBarTitleDisplayMode(.large)
    .toolbar(destination == nil ? .automatic : .hidden, for: .navigationBar)
    .onChange(of: store.account?.mid) { _, _ in store.homeFeeds = MobileHomeFeeds() }
    .onChange(of: navigation.preferences) { normalizeTab() }
    .onChange(of: self.tab) { old, value in
      store.phoneHomeTab = value
      store.browseDestination = value == 0 ? .recommend : value == 1 ? .popular : .regions
      store.isRecommendedVisible = value == 0
      if old != 0 && value == 0 { store.homeReturnRevision += 1 }
    }
    .onAppear { normalizeTab(); store.phoneHomeTab = destination ?? self.tab }
    .toolbar {
      if destination == nil {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink {
            MobileSearch(store: store)
          } label: {
            Image(systemName: "magnifyingglass")
          }.accessibilityLabel("搜索")
        }
      }
    }
  }
  private func normalizeTab() {
    guard destination == nil else { return }
    let page: StartPage = tab == 0 ? .recommend : tab == 1 ? .popular : .regions
    if !navigation.preferences.allows(page), let first = navigation.preferences.visible.first(where: \.isHome) {
      tab = first == .recommend ? 0 : first == .popular ? 1 : 2
    }
  }
}
private struct MobileSearchField: ViewModifier {
  @Binding var text: String
  var enabled: Bool
  func body(content: Content) -> some View {
    if enabled {
      content.searchable(
        text: $text, placement: .navigationBarDrawer(displayMode: .always),
        prompt: "关键词、BV 号或视频链接")
    } else {
      content
    }
  }
}
struct MobileSearch: View {
  @Bindable var store: Store
  var initialQuery = ""
  var showsSearchField = true
  @State private var text = ""
  @State private var query = ""
  @State private var options = SearchOptions()
  @State private var history = UserDefaults.standard.stringArray(forKey: "searchHistory") ?? []
  @State private var suggestions: [String] = []
  @State private var filters = false
  @State private var users: [SearchUser] = []
  @State private var userPage = 0
  @State private var userBusy = false
  @State private var userMore = true
  @State private var userError: String?
  @State private var userGeneration = UUID()
  var body: some View {
    Group {
      if query.isEmpty {
        List {
          if !suggestions.isEmpty {
            Section("搜索联想") {
              ForEach(suggestions, id: \.self) { term in
                Button(term) { submit(term) }.foregroundStyle(.primary)
              }
            }
          }
          if !history.isEmpty {
            Section {
              ForEach(history, id: \.self) { term in
                Button(term) { submit(term) }.foregroundStyle(.primary)
              }
              Button("清空历史", role: .destructive) {
                history = []
                UserDefaults.standard.removeObject(forKey: "searchHistory")
              }
            } header: {
              Text("搜索历史")
            }
          }
          Section { Text("输入关键词、BV 号或视频链接").foregroundStyle(.secondary) }
        }
      } else if options.users {
        List {
          ForEach(users) { user in
            NavigationLink {
              MobileProfile(store: store, mid: user.id)
            } label: {
              HStack(spacing: 12) {
                MobileAvatar(url: user.face).frame(width: 50, height: 50).clipShape(.circle)
                VStack(alignment: .leading) {
                  Text(user.name)
                  Text(user.bio).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                  Text("\(user.fans) 位粉丝").font(.caption)
                }
              }
            }
          }
          if userBusy { ProgressView("正在搜索用户") }
          if users.isEmpty && !userBusy && userError == nil {
            ContentUnavailableView.search(text: query)
          }
          if let userError {
            MobileError(text: userError) { Task { await loadUsers(reset: users.isEmpty) } }
          }
          if userMore && !userBusy { Button("加载更多用户") { Task { await loadUsers() } } }
        }.task(id: "\(query):\(options)") { await loadUsers(reset: true) }
      } else {
        MobileVideoList(title: query, store: store) { page in
          try await store.api.search(query, page: page, options: options)
        }.id("\(query):\(options)")
      }
    }.task { if query.isEmpty && !initialQuery.isEmpty { submit(initialQuery) } }
      .navigationTitle("搜索")
      .modifier(MobileSearchField(text: $text, enabled: showsSearchField))
      .onSubmit(of: .search) { submit(text) }
      .onChange(of: text) { _, value in
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { query = "" }
      }
      .task(id: text) {
        suggestions = []
        guard !text.isEmpty else { return }
        do {
          try await Task.sleep(for: .milliseconds(250))
          let result = try await store.api.suggestions(text)
          try Task.checkCancellation()
          suggestions = result
        } catch {}
      }
      .toolbar {
        Button {
          filters = true
        } label: {
          Image(systemName: "line.3.horizontal.decrease")
        }.accessibilityLabel("搜索筛选")
      }
      .sheet(isPresented: $filters) {
        NavigationStack {
          Form {
            Picker("搜索类型", selection: $options.users) {
              Text("视频").tag(false)
              Text("用户").tag(true)
            }
            Picker("排序", selection: $options.order) {
              Text("综合").tag("totalrank")
              Text("最多播放").tag("click")
              Text("最新").tag("pubdate")
              Text("最多弹幕").tag("dm")
              Text("最多收藏").tag("stow")
            }
            Picker("时长", selection: $options.duration) {
              Text("全部").tag(0)
              Text("10分钟以下").tag(1)
              Text("10–30分钟").tag(2)
              Text("30–60分钟").tag(3)
              Text("60分钟以上").tag(4)
            }
            Picker("发布", selection: $options.days) {
              Text("全部").tag(0)
              Text("最近一天").tag(1)
              Text("最近一周").tag(7)
              Text("最近半年").tag(180)
            }
          }.navigationTitle("搜索筛选").toolbar { Button("完成") { filters = false } }
        }.presentationDetents([.medium, .large])
      }
  }
  private func submit(_ term: String) {
    let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return }
    if let bvid = videoID(term) {
      text = term
      store.open(bvid)
      return
    }
    text = term
    query = term
    history.removeAll { $0 == term }
    history.insert(term, at: 0)
    history = Array(history.prefix(30))
    UserDefaults.standard.set(history, forKey: "searchHistory")
  }
  private func loadUsers(reset: Bool = false) async {
    if reset {
      userGeneration = UUID()
      userBusy = false
      userPage = 0
      users = []
      userMore = true
    }
    guard !userBusy, userMore else { return }
    let token = userGeneration
    userBusy = true
    userError = nil
    let requested = query
    defer { if token == userGeneration { userBusy = false } }
    do {
      let rows = try await store.api.searchUsers(requested, page: userPage + 1)
      try Task.checkCancellation()
      guard requested == query, token == userGeneration else { return }
      var ids = Set(reset ? [] : users.map(\.id))
      let additions = rows.filter { ids.insert($0.id).inserted }
      users = reset ? additions : users + additions
      userPage += 1
      userMore = !rows.isEmpty
    } catch {
      if token == userGeneration && !(error is CancellationError) {
        userError = error.localizedDescription
      }
    }
  }
}

extension NavigationLink where Label == SwiftUI.Label<Text, Image> {
  init(_ title: String, systemImage: String, @ViewBuilder destination: () -> Destination) {
    self.init(destination: destination) { SwiftUI.Label(title, systemImage: systemImage) }
  }
}

func compactCount(_ count: Int) -> String {
  if count >= 100_000_000 { return String(format: "%.1f亿", Double(count) / 100_000_000) }
  if count >= 10_000 { return String(format: "%.1f万", Double(count) / 10_000) }
  return String(max(0, count))
}

private struct MobilePlayerAccessory: ViewModifier {
  @Bindable var store: Store
  func body(content: Content) -> some View {
    // Keep the native accessory mounted underneath presented sheets. Dismissing
    // a video no longer removes/reinserts the tab bar's glass material.
    if #available(iOS 26.1, *) {
      content.tabViewBottomAccessory(isEnabled: store.isPlaybackOpen) {
        MobileMiniPlayer(store: store)
      }
    } else {
      content.tabViewBottomAccessory { if store.isPlaybackOpen { MobileMiniPlayer(store: store) } }
    }
  }
}
