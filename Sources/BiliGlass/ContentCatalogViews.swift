import SwiftUI

struct SeasonCatalogPage: View {
  @Bindable var store: Store
  @Bindable var model: SeasonCatalogModel
  let cinema: Bool
  @State private var category = 1
  @State private var followed = false
  @State private var query = ""
  @State private var keyword = ""
  @State private var selected: SeasonSummary?
  @State private var loginAfterDismiss = false
  private var type: Int { cinema && category == 1 ? 2 : category }
  private var requestKey: String { "\(type):\(followed):\(keyword):\(store.account?.mid ?? 0)" }
  private var categories: [(Int, String)] { cinema ? [(2,"电影"),(5,"电视剧"),(3,"纪录片"),(7,"综艺")] : [(1,"番剧"),(4,"国创")] }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 16) {
        Text(cinema ? "影视" : "追番").font(AppLayout.pageTitle)
        Picker("内容", selection: Binding(get: { type }, set: { category = $0 })) {
          ForEach(categories, id: \.0) { Text($0.1).tag($0.0) }
        }.frame(width: 150)
        Picker("列表", selection: $followed) {
          Text("发现").tag(false); Text(cinema ? "我的追剧" : "我的追番").tag(true)
        }.pickerStyle(.segmented).frame(width: 190)
        Spacer()
        Button { Task { await load(refresh: true) } } label: { Image(systemName: "arrow.clockwise") }
          .help("刷新").disabled(model.loading)
      }
      if !followed {
        HStack(spacing: 12) {
          TextField(cinema ? "搜索影视" : "搜索番剧", text: $query).textFieldStyle(.roundedBorder)
            .onSubmit { keyword = query.trimmingCharacters(in: .whitespacesAndNewlines) }
          Button("搜索") { keyword = query.trimmingCharacters(in: .whitespacesAndNewlines) }
          if !keyword.isEmpty { Button("清除") { query = ""; keyword = "" } }
        }
      }
      if followed && store.account == nil {
        ContentUnavailableView {
          Label(cinema ? "登录后查看我的追剧" : "登录后查看我的追番", systemImage: "person.crop.circle")
        } actions: { Button("登录") { store.login() } }
      } else {
        if let error = model.error { ErrorBanner(text: error) { Task { await load(refresh: true) } } }
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 18)], spacing: 22) {
            ForEach(model.items) { item in
              Button { selected = item } label: {
                VStack(alignment: .leading, spacing: 8) {
                  Thumbnail(url: item.cover, mode: .fill).aspectRatio(0.72, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: AppLayout.mediaRadius))
                    .overlay(alignment: .topTrailing) {
                      if !item.badge.isEmpty { Text(item.badge).font(.caption2).padding(5).background(biliPink, in: .rect(cornerRadius: AppLayout.controlRadius)).foregroundStyle(.white).padding(7) }
                    }
                  Text(item.title).font(.callout.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                  Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.contentShape(.rect)
              }.buttonStyle(.pointerPlain).cardHover()
            }
          }.padding(4)
          if model.loading { ProgressView().padding(20) }
          else if model.hasMore { Button("加载更多") { Task { await load(more: true) } }.padding(16) }
          else if model.items.isEmpty && model.error == nil { ContentUnavailableView.search(text: keyword) }
        }.modifier(RememberedScroll(memory: model.position))
      }
    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .floatingGlass(AppLayout.panelRadius).buttonStyle(.pointerGlass)
      .task(id: requestKey) { await load() }
      .sheet(item: $selected, onDismiss: {
        if loginAfterDismiss { loginAfterDismiss = false; store.login() }
        else if model.items.isEmpty { Task { await load() } }
      }) { item in
        SeasonDetailPanel(store: store, summary: item, cinema: cinema,
          onLogin: { loginAfterDismiss = true; selected = nil },
          onPlay: { episode, season in selected = nil; store.openEpisode(episode, season: season) })
      }
  }
  private func load(refresh: Bool = false, more: Bool = false) async {
    await model.load(api: store.api, type: type, followed: followed, keyword: followed ? "" : keyword, refresh: refresh, more: more)
  }
}

private struct SeasonDetailPanel: View {
  @Bindable var store: Store
  let summary: SeasonSummary
  let cinema: Bool
  let onLogin: () -> Void
  let onPlay: (SeasonEpisode, SeasonDetail) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var detail: SeasonDetail?
  @State private var loading = true
  @State private var changingFollow = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack { Text(summary.title).font(.title2.weight(.semibold)); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
      if loading { ProgressView("正在读取剧集…").frame(maxWidth: .infinity, maxHeight: .infinity) }
      else if let detail {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
              Thumbnail(url: detail.cover, mode: .fill).frame(width: 120, height: 166).clipShape(.rect(cornerRadius: AppLayout.mediaRadius))
              VStack(alignment: .leading, spacing: 14) {
                Text(detail.description).font(.callout).textSelection(.enabled)
                Button(store.account == nil ? (cinema ? "登录后追剧" : "登录后追番") : detail.following ? "取消追看" : (cinema ? "追剧" : "追番")) {
                  if store.account == nil { onLogin() } else { Task { await follow() } }
                }.disabled(changingFollow).tint(biliPink)
              }
            }
            ForEach(detail.episodeGroups) { group in
            Text(group.title + " · \(group.episodes.count)").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
              ForEach(group.episodes) { episode in
                Button { onPlay(episode, detail) } label: {
                  VStack(alignment: .leading, spacing: 6) {
                    Text(episode.title).font(.callout.weight(.medium)).lineLimit(2)
                    if !episode.badge.isEmpty { Text(episode.badge).font(.caption).foregroundStyle(.secondary) }
                    if episode.areaLimited { Text("当前地区不可播放").font(.caption).foregroundStyle(.secondary) }
                  }.frame(maxWidth: .infinity, minHeight: 50, alignment: .leading).padding(12).contentShape(.rect(cornerRadius: AppLayout.mediaRadius))
                }.buttonStyle(InterfacePressStyle())
                  .appGlass(AppLayout.itemRadius, tint: store.playback.currentEpisodeID == episode.id ? biliPink.opacity(0.18) : .clear, interactive: true, regular: true)
                  .disabled(episode.cid <= 0 || episode.bvid.isEmpty || episode.areaLimited)
              }
            }
            }
            if detail.episodes.isEmpty { Text("暂未提供可播放的剧集").foregroundStyle(.secondary) }
          }.padding(4)
        }
      }
      if let error { Text(error).font(.callout).foregroundStyle(.secondary); if detail == nil { Button("重试") { Task { await load() } } } }
    }.padding(24).frame(width: 800, height: 620).background { GlassBackdrop() }.appAppearance().buttonStyle(.pointerGlass)
      .task(id: store.account?.mid) { await load() }
  }
  private func load() async {
    loading = true; error = nil
    do { detail = try await store.api.season(id: summary.id) }
    catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    loading = false
  }
  private func follow() async {
    guard let detail else { return }
    changingFollow = true; error = nil
    defer { changingFollow = false }
    do {
      try await store.api.followSeason(detail.id, following: !detail.following)
      self.detail?.following.toggle(); store.bangumiCatalog.reset(); store.cinemaCatalog.reset()
    } catch { self.error = error.localizedDescription }
  }
}

struct LivePage: View {
  @Bindable var store: Store
  var body: some View {
    Group {
      if LiveAvailability.enabled { LiveBrowserPage(store: store) }
      else { ContentUnavailableView("开发中", systemImage: "dot.radiowaves.left.and.right") }
    }.frame(maxWidth: .infinity, maxHeight: .infinity).floatingGlass(AppLayout.panelRadius)
  }
}

private struct LiveBrowserPage: View {
  @Bindable var store: Store
  @State private var query = ""
  var body: some View {
    let model = store.liveCatalog
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("直播").font(AppLayout.pageTitle); Spacer()
        Button { query = ""; Task { await model.load(api: store.api, refresh: true) } } label: { Image(systemName: "arrow.clockwise") }.help("刷新推荐")
      }
      HStack(spacing: 12) {
        TextField("搜索直播、输入房间号或直播链接", text: $query).textFieldStyle(.roundedBorder).onSubmit { search() }
        Button("搜索") { search() }.disabled(model.loading)
      }
      if let error = model.error { ErrorBanner(text: error) { search() } }
      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 390), spacing: 18)], spacing: 20) {
          ForEach(model.rooms) { room in
            Button { store.openLive(room) } label: {
              VStack(alignment: .leading, spacing: 8) {
                Thumbnail(url: room.cover, mode: .fill).aspectRatio(16.0 / 9, contentMode: .fit)
                  .clipShape(.rect(cornerRadius: AppLayout.mediaRadius))
                  .overlay(alignment: .bottomTrailing) {
                    Text(room.isLive ? "直播中" : "未开播").font(.caption).padding(6).background(.black.opacity(0.65), in: .capsule).foregroundStyle(.white).padding(8)
                  }
                Text(room.title).font(.callout.weight(.medium)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                HStack { Text(room.author); Spacer(); Text(room.area) }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }.contentShape(.rect)
            }.buttonStyle(.pointerPlain).cardHover()
          }
        }.padding(4)
        if model.loading { ProgressView().padding(24) }
        else if model.rooms.isEmpty && model.error == nil { ContentUnavailableView.search(text: query) }
      }.modifier(RememberedScroll(memory: model.position))
    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).floatingGlass(AppLayout.panelRadius).buttonStyle(.pointerGlass)
      .task { await model.load(api: store.api) }
      .sheet(item: $store.activeLiveRoom, onDismiss: { store.livePlayback.stop() }) { room in LivePlayerPanel(store: store, room: room) }
  }
  private func search() { Task { await store.liveCatalog.load(api: store.api, keyword: query.trimmingCharacters(in: .whitespacesAndNewlines), refresh: true) } }
}
