import SwiftUI

struct NativePerson: Identifiable {
  let id: Int
  let name: String
  let face: String
  let bio: String
}
struct SpaceSheet: Identifiable {
  enum Kind { case following, followers, dynamic, collections, account }
  let id = UUID()
  let mid: Int
  let kind: Kind
}
struct DynamicEntry: Identifiable {
  let id: String
  let mid: Int
  let author: String
  let face: String
  let date: String
  let text: String
  let original: String
  let pictures: [String]
  let video: Video?
  let commentID: Int
  let commentType: Int
  var liked = false
  var likeCount = 0
  var repostCount = 0
  var commentCount = 0
  var attachment: DynamicAttachment? = nil
  var unavailableText = ""
  static func parse(_ raw: [String: Any]) -> DynamicEntry? {
    guard let id = raw["id_str"] as? String else { return nil }
    let modules = raw["modules"] as? [String: Any] ?? [:]
    let author = modules["module_author"] as? [String: Any] ?? [:]
    let body = modules["module_dynamic"] as? [String: Any] ?? [:]
    let original = raw["orig"] as? [String: Any] ?? [:]
    let originalModules = original["modules"] as? [String: Any] ?? [:]
    let originalBody = originalModules["module_dynamic"] as? [String: Any] ?? [:]
    let originalAuthor = originalModules["module_author"] as? [String: Any] ?? [:]
    let originalText = (originalBody["desc"] as? [String: Any])?["text"] as? String ?? ""
    let major = body["major"] as? [String: Any] ?? originalBody["major"] as? [String: Any] ?? [:]
    let opus = major["opus"] as? [String: Any] ?? [:]
    let summary = opus["summary"] as? [String: Any] ?? [:]
    let text =
      (body["desc"] as? [String: Any])?["text"] as? String ?? summary["text"] as? String ?? opus[
        "title"] as? String ?? ""
    let draw = major["draw"] as? [String: Any] ?? [:]
    let pictures =
      (draw["items"] as? [[String: Any]] ?? []).compactMap { $0["src"] as? String }
      + (opus["pics"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
    let basic = raw["basic"] as? [String: Any] ?? [:]
    let stats = modules["module_stat"] as? [String: Any] ?? [:]
    let likes = stats["like"] as? [String: Any] ?? [:]
    var video: Video?
    if let archive = major["archive"] as? [String: Any], let bvid = archive["bvid"] as? String {
      let duration = (archive["duration_text"] as? String ?? "0").split(separator: ":").reduce(0) {
        $0 * 60 + (Int($1) ?? 0)
      }
      let stat = archive["stat"] as? [String: Any] ?? [:]
      let views = stat["play"] as? Int ?? 0
      video = Video(
        bvid: bvid, title: archive["title"] as? String ?? "视频",
        cover: archive["cover"] as? String ?? "",
        author: author["name"] as? String ?? "", duration: duration, views: views)
    }
    return DynamicEntry(
      id: id, mid: author["mid"] as? Int ?? 0, author: author["name"] as? String ?? "用户",
      face: author["face"] as? String ?? "", date: author["pub_time"] as? String ?? "",
      text: text,
      original: originalText.isEmpty
        ? "" : "@" + (originalAuthor["name"] as? String ?? "") + "\n" + originalText,
      pictures: Array(pictures.prefix(9)), video: video,
      commentID: Int(basic["comment_id_str"] as? String ?? "") ?? basic["comment_id"] as? Int ?? 0,
      commentType: basic["comment_type"] as? Int ?? 17,
      liked: likes["status"] as? Bool ?? false, likeCount: likes["count"] as? Int ?? 0,
      repostCount: (stats["forward"] as? [String: Any])?["count"] as? Int ?? 0,
      commentCount: (stats["comment"] as? [String: Any])?["count"] as? Int ?? 0,
      attachment: DynamicAttachment.parse(major: major),
      unavailableText: (major["none"] as? [String: Any])?["tips"] as? String ??
        (original["type"] as? String == "DYNAMIC_TYPE_NONE" ? "原动态已无法查看" : ""))
  }
}
#if os(macOS)
private enum NativeDynamicFilter: String, CaseIterable {
  case all = "全部", video = "视频", textAndImages = "图文"
  func includes(_ entry: DynamicEntry) -> Bool {
    switch self {
    case .all: return true
    case .video: return entry.video != nil
    case .textAndImages:
      return entry.video == nil && entry.attachment == nil && entry.unavailableText.isEmpty
        && (!entry.text.isEmpty || !entry.original.isEmpty || !entry.pictures.isEmpty)
    }
  }
}
struct NativeDynamicsPage: View {
  @Bindable var store: Store
  var mid: Int? = nil
  @State private var items: [DynamicEntry] = []
  @State private var offset = ""
  @State private var hasMore = true
  @State private var loading = false
  @State private var error: String?
  @State private var detail: DynamicEntry?
  @State private var identity = UUID()
  @State private var draft = DynamicDraft()
  @State private var composing = false
  @State private var filter = NativeDynamicFilter.all
  private var visibleItems: [DynamicEntry] { items.filter(filter.includes) }
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        HStack {
          Text(mid == nil ? "关注动态" : "动态").font(.title2.bold())
          Spacer()
          Button("发布动态") { composing = true }.buttonStyle(.appGlassButton).disabled(store.account == nil)
          Button {
            Task { await load(reset: true) }
          } label: {
            Image(systemName: "arrow.clockwise")
          }.buttonStyle(.appGlassButton).disabled(loading).help("刷新动态")
        }.padding(16).floatingGlass(22).contentShape(.rect(cornerRadius: 22))
        Picker("动态类型", selection: $filter) {
          ForEach(NativeDynamicFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).frame(maxWidth: 320).accessibilityIdentifier("dynamic-type-filter")
        if let error { ErrorBanner(text: error) { Task { await load(reset: true) } } }
        ForEach(visibleItems) { item in
          VStack(alignment: .leading, spacing: 14) {
            DynamicContent(entry: item, store: store)
            DynamicActions(store: store, entry: item, comment: item.commentID > 0 ? { detail = item } : nil)
          }.padding(20).frame(maxWidth: .infinity, alignment: .leading).floatingGlass(24)
        }
        if !items.isEmpty && visibleItems.isEmpty && !loading {
          ContentUnavailableView("已加载内容中没有\(filter.rawValue)动态", systemImage: "line.3.horizontal.decrease",
            description: Text(hasMore ? "可以继续加载更早的动态，或切回全部。" : "可以切回全部查看其他类型的动态。"))
            .frame(maxWidth: .infinity)
        }
        if loading {
          ProgressView().frame(maxWidth: .infinity).padding(20)
        } else if !items.isEmpty {
          LoadMoreFooter(loading: loading, hasMore: hasMore, error: error, count: items.count, title: "加载更多动态") {
            Task { await load(reset: false) }
          }
        } else if items.isEmpty && error == nil {
          ContentUnavailableView("暂无动态", systemImage: "rectangle.stack").frame(maxWidth: .infinity)
        }
      }.padding(AppLayout.pageInset)
    }.task(id: mid) { await load(reset: true) }.sheet(item: $detail) { entry in
      NativeDynamicDetail(entry: entry, store: store)
    }.sheet(isPresented: $composing) {
      DynamicComposer(store: store, draft: draft) { store.interactionMessage = "动态已发布"; Task { await load(reset: true) } }
    }
  }
  private func load(reset: Bool) async {
    if reset {
      identity = UUID()
      loading = false
      items = []
    }
    guard !loading else { return }
    let token = identity
    loading = true
    error = nil
    defer { if token == identity { loading = false } }
    do {
      let path =
        mid == nil ? "/x/polymer/web-dynamic/v1/feed/all" : "/x/polymer/web-dynamic/v1/feed/space"
      var query = [
        "timezone_offset": "-660", "offset": reset ? "" : offset,
        "features": "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote",
      ]
      if let mid { query["host_mid"] = String(mid) } else { query["type"] = "all" }
      let data = try await store.api.request(path, query)
      try Task.checkCancellation()
      guard token == identity else { return }
      let new = (data["items"] as? [[String: Any]] ?? []).compactMap(DynamicEntry.parse)
      var ids = reset ? Set<String>() : Set(items.map(\.id))
      let unique = new.filter { ids.insert($0.id).inserted }
      items = reset ? unique : items + unique
      offset = data["offset"] as? String ?? ""
      hasMore = data["has_more"] as? Bool ?? (data["has_more"] as? Int == 1)
    } catch {
      if token == identity && !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}
struct DynamicContent: View {
  let entry: DynamicEntry
  @Bindable var store: Store
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Button {
          store.showProfile(entry.mid)
        } label: {
          Thumbnail(url: entry.face, mode: .fill, placeholder: "person.crop.circle.fill").frame(
            width: 38, height: 38
          ).clipShape(Circle())
        }.buttonStyle(.plain)
        VStack(alignment: .leading, spacing: 4) {
          Text(entry.author).font(.headline)
          Text(entry.date).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      }
      if !entry.text.isEmpty {
        Text(entry.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      if !entry.original.isEmpty {
        Text(entry.original).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
          .padding(14).appGlass(14)
      }
      if let video = entry.video {
        Button {
          store.open(video.bvid)
        } label: {
          HStack(spacing: 14) {
            Thumbnail(url: video.cover, mode: .fill).frame(width: 180, height: 102).clipShape(
              RoundedRectangle(cornerRadius: 12))
            Text(video.title).font(.headline).lineLimit(3).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill").font(.title)
          }.padding(12).appGlass(18).contentShape(.rect(cornerRadius: 18))
        }.buttonStyle(.plain)
      }
      if !entry.pictures.isEmpty {
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 170, maximum: 280), spacing: 10)], spacing: 10
        ) {
          ForEach(entry.pictures, id: \.self) { image in
            Thumbnail(url: image, mode: .fit).aspectRatio(1, contentMode: .fit).clipShape(
              RoundedRectangle(cornerRadius: 12))
          }
        }
      }
    }
  }
}
struct NativeDynamicDetail: View {
  let entry: DynamicEntry
  @Bindable var store: Store
  @State private var comments = Comments()
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("动态").font(.headline)
        Spacer()
        Button("完成") { dismiss() }.buttonStyle(.appGlassButton)
      }.padding(16)
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          DynamicContent(entry: entry, store: store)
          DynamicActions(store: store, entry: entry)
          CommentsView(
            store: store, aid: entry.commentID, type: entry.commentType, model: comments,
            verificationURL: URL(string: "https://t.bilibili.com/" + entry.id))
        }.padding(22)
      }.floatingGlass(24).padding(.horizontal, 16).padding(.bottom, 16)
    }.frame(minWidth: 820, minHeight: 680).background { GlassBackdrop() }.onDisappear {
      comments.stop()
    }.onChange(of: store.navigationRevision) { dismiss() }
  }
}
struct NativeRelationsPage: View {
  @Bindable var store: Store
  let mid: Int
  let followers: Bool
  @State private var people: [NativePerson] = []
  @State private var page = 0
  @State private var loading = false
  @State private var hasMore = true
  @State private var error: String?
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 14) {
        Text(followers ? "粉丝" : "关注").font(.title2.bold()).padding(12)
        if let error { ErrorBanner(text: error) { Task { await load() } } }
        ForEach(people) { person in
          Button {
            store.showProfile(person.id)
          } label: {
            HStack(spacing: 14) {
              Thumbnail(url: person.face, mode: .fill, placeholder: "person.crop.circle.fill")
                .frame(width: 48, height: 48).clipShape(
                  Circle())
              VStack(alignment: .leading, spacing: 6) {
                Text(person.name).font(.headline)
                Text(person.bio).font(.callout).foregroundStyle(.secondary).lineLimit(2)
              }
              Spacer()
              Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(18).floatingGlass(22).contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
        if loading {
          ProgressView().frame(maxWidth: .infinity)
        } else if hasMore {
          Button("加载更多") { Task { await load() } }.buttonStyle(.appGlassButton).frame(maxWidth: .infinity)
        }
      }.padding(AppLayout.pageInset)
    }.task { await load() }
  }
  private func load() async {
    guard !loading else { return }
    loading = true
    error = nil
    defer { loading = false }
    do {
      let data = try await store.api.request(
        followers ? "/x/relation/followers" : "/x/relation/followings",
        ["vmid": String(mid), "pn": String(page + 1), "ps": "30", "order": "desc"])
      try Task.checkCancellation()
      let raw = data["list"] as? [[String: Any]] ?? []
      let new = raw.compactMap { row -> NativePerson? in
        guard let id = row["mid"] as? Int else { return nil }
        return NativePerson(
          id: id, name: row["uname"] as? String ?? "用户", face: row["face"] as? String ?? "",
          bio: row["sign"] as? String ?? "")
      }
      var ids = Set(people.map(\.id))
      people += new.filter { ids.insert($0.id).inserted }
      page += 1
      hasMore = raw.count >= 30
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }
}

struct NativeCollection: Identifiable {
  var id: String { "\(series):\(number)" }
  let number: Int
  let series: Bool
  let title: String
  let cover: String
  let count: Int
}
struct NativeCollectionsPage: View {
  @Bindable var store: Store
  let mid: Int
  @State private var rows: [NativeCollection] = []
  @State private var selected: NativeCollection?
  @State private var loading = false
  @State private var page = 0
  @State private var hasMore = true
  @State private var error: String?
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        Text("合集").font(.title2.bold()).padding(12)
        if let error { ErrorBanner(text: error) { Task { await load() } } }
        ForEach(rows) { row in
          Button {
            selected = row
          } label: {
            HStack(spacing: 16) {
              Thumbnail(url: row.cover, mode: .fill).frame(width: 140, height: 88).clipShape(
                RoundedRectangle(cornerRadius: 12))
              VStack(alignment: .leading, spacing: 9) {
                Text(row.title).font(.headline)
                Text("\(row.count) 个视频").font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(16).floatingGlass(22).contentShape(.rect(cornerRadius: 22))
          }.buttonStyle(.plain)
        }
        if loading {
          ProgressView().frame(maxWidth: .infinity).padding(20)
        } else if rows.isEmpty && error == nil {
          ContentUnavailableView("暂无合集", systemImage: "square.stack").frame(maxWidth: .infinity)
        } else if hasMore {
          Button("加载更多") { Task { await load() } }.buttonStyle(.appGlassButton).frame(maxWidth: .infinity)
        }
      }.padding(AppLayout.pageInset)
    }.task { await load() }.sheet(item: $selected) { collection in
      NativeCollectionVideos(store: store, mid: mid, collection: collection)
    }.onChange(of: store.navigationRevision) { selected = nil }
  }
  private func load() async {
    guard !loading else { return }
    loading = true
    error = nil
    defer { loading = false }
    do {
      let data = try await store.api.request(
        "/x/polymer/web-space/seasons_series_list",
        ["mid": String(mid), "page_num": String(page + 1), "page_size": "20"])
      try Task.checkCancellation()
      let lists = data["items_lists"] as? [String: Any] ?? [:]
      var new: [NativeCollection] = []
      for series in [false, true] {
        for raw in lists[series ? "series_list" : "seasons_list"] as? [[String: Any]] ?? [] {
          let meta = raw["meta"] as? [String: Any] ?? [:]
          guard let id = meta[series ? "series_id" : "season_id"] as? Int else { continue }
          let preview = (raw["archives"] as? [[String: Any]])?.first
          new.append(
            NativeCollection(
              number: id, series: series, title: meta["name"] as? String ?? "合集",
              cover: meta["cover"] as? String ?? preview?["pic"] as? String ?? "",
              count: meta["total"] as? Int ?? 0))
        }
      }
      var ids = Set(rows.map(\.id))
      rows += new.filter { ids.insert($0.id).inserted }
      page += 1
      hasMore = new.count >= 20
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }
}
struct NativeCollectionVideos: View {
  @Bindable var store: Store
  let mid: Int
  let collection: NativeCollection
  @Environment(\.dismiss) private var dismiss
  @State private var rows: [Video] = []
  @State private var page = 0
  @State private var hasMore = true
  @State private var loading = false
  @State private var error: String?
  var body: some View {
    VStack {
      HStack {
        Text(collection.title).font(.title2.bold())
        Spacer()
        Button("完成") { dismiss() }.buttonStyle(.appGlassButton)
      }.padding(20)
      ScrollView {
        LazyVStack(spacing: 20) {
          if let error { ErrorBanner(text: error) { Task { await load() } } }
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: 18)], spacing: 18
          ) {
            ForEach(rows) { video in
              Button {
                store.open(video.bvid)
              } label: {
                VideoCard(video: video)
              }.buttonStyle(.plain)
            }
          }
          if loading {
            ProgressView()
          } else if hasMore {
            Button("加载更多") { Task { await load() } }.buttonStyle(.appGlassButton)
          }
        }.padding(20)
      }
    }.frame(minWidth: 850, minHeight: 650).background { GlassBackdrop() }.task { await load() }
      .onChange(of: store.navigationRevision) { dismiss() }
  }
  private func load() async {
    guard !loading else { return }
    loading = true
    error = nil
    defer { loading = false }
    do {
      let path =
        collection.series ? "/x/series/archives" : "/x/polymer/web-space/seasons_archives_list"
      var query = [
        "mid": String(mid),
        collection.series ? "series_id" : "season_id": String(collection.number),
      ]
      query[collection.series ? "pn" : "page_num"] = String(page + 1)
      query[collection.series ? "ps" : "page_size"] = "30"
      let data = try await store.api.request(path, query)
      try Task.checkCancellation()
      let new = (data["archives"] as? [[String: Any]] ?? []).compactMap(Video.parse)
      var ids = Set(rows.map(\.id))
      rows += new.filter { ids.insert($0.id).inserted }
      page += 1
      hasMore = new.count >= 30
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }
}
struct NativeAccountPage: View {
  @State private var showBlacklist = false
  @Bindable var store: Store
  @State private var details: [String: Any] = [:]
  @State private var accountError: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      if let account = store.account {
        HStack(spacing: 18) {
          Thumbnail(url: account.face, mode: .fill, placeholder: "person.crop.circle.fill").frame(
            width: 68, height: 68
          ).clipShape(Circle())
          VStack(alignment: .leading, spacing: 8) {
            Text(account.name).font(.title2.bold())
            Text("UID " + String(account.mid)).font(.caption.monospacedDigit()).foregroundStyle(
              .secondary
            ).textSelection(.enabled)
          }
        }
        Divider()
        if let accountError {
          Text(accountError).font(.callout).foregroundStyle(.secondary)
        } else if details.isEmpty {
          ProgressView("正在加载账户信息")
        } else {
          LabeledContent(
            "等级",
            value: "Lv. "
              + String((details["level_info"] as? [String: Any])?["current_level"] as? Int ?? 0))
          LabeledContent("硬币", value: (details["money"] as? Double ?? 0).formatted())
          LabeledContent("大会员", value: (details["vipStatus"] as? Int ?? 0) == 1 ? "已开通" : "未开通")
        }
        Link("管理哔哩哔哩账户", destination: URL(string: "https://account.bilibili.com/account/home")!)
          .font(.callout)
        Button { showBlacklist = true } label: { Label("黑名单", systemImage: "person.slash") }
          .buttonStyle(.appGlassButton).accessibilityIdentifier("account-blacklist")
        Button("重新登录") { store.login() }.buttonStyle(.appGlassButton)
        Button("退出登录", role: .destructive) { store.logout() }.buttonStyle(.appGlassButton)
      }
      Spacer(minLength: 0)
    }.padding(24).floatingGlass(24)
      .sheet(isPresented: $showBlacklist) { BlockedAuthorsPage(store: store) }
      .task {
      do { details = try await store.api.request("/x/web-interface/nav") } catch {
        accountError = error.localizedDescription
      }
    }
  }
}

#endif
