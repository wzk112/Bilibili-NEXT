import PhotosUI
import SwiftUI

struct MobileDynamics: View {
  @Bindable var store: Store
  @State private var items: [DynamicEntry] = []
  @State private var offset = ""
  @State private var hasMore = true
  @State private var busy = false
  @State private var error: String?
  @State private var composing = false
  @State private var draft = DynamicDraft()
  @State private var generation = UUID()
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        if store.account == nil {
          ContentUnavailableView {
            Label("登录后查看关注动态", systemImage: "person.2")
          } actions: {
            Button("登录") { store.login() }.buttonStyle(.appGlassButton)
          }
        }
        if store.account != nil && items.isEmpty && !busy && error == nil {
          ContentUnavailableView(
            "暂无动态", systemImage: "person.2",
            description: Text("关注 UP 主后，新动态会显示在这里。下拉可以刷新。"))
        }
        ForEach(items) { entry in
          MobileDynamicCard(store: store, entry: entry).padding(16).background(
            .regularMaterial, in: .rect(cornerRadius: AppMetrics.panelRadius))
        }
        if busy { ProgressView() }
        if let error {
          MobileError(text: error) { Task { await load(reset: items.isEmpty || !hasMore) } }
        }
        if !items.isEmpty && hasMore && !busy {
          Button("加载更多动态") { Task { await load() } }.buttonStyle(.appGlassButton)
        }
      }.padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
    }.navigationTitle("动态").toolbar {
      Button {
        if store.account == nil { store.login() } else { composing = true }
      } label: {
        Image(systemName: "square.and.pencil")
      }.accessibilityLabel("发布动态")
    }
    .task(id: store.account?.mid) { await load(reset: true) }.refreshable {
      await load(reset: true)
    }
    .sheet(isPresented: $composing) {
      MobileDynamicComposer(store: store, draft: draft) { Task { await load(reset: true) } }
    }
  }
  private func load(reset: Bool = false) async {
    guard store.account != nil else {
      generation = UUID()
      items = []
      offset = ""
      busy = false
      error = nil
      return
    }
    if reset {
      generation = UUID()
      busy = false
      hasMore = true
    }
    guard !busy, hasMore else { return }
    let token = generation
    busy = true
    error = nil
    defer { if token == generation { busy = false } }
    do {
      let data = try await store.api.request(
        "/x/polymer/web-dynamic/v1/feed/all",
        [
          "type": "all", "offset": reset ? "" : offset,
          "timezone_offset": String(-TimeZone.current.secondsFromGMT() / 60),
          "features": "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote",
        ])
      try Task.checkCancellation()
      guard token == generation else { return }
      let rows = (data["items"] as? [[String: Any]] ?? []).compactMap(DynamicEntry.parse)
      var ids = Set(reset ? [] : items.map(\.id))
      let additions = rows.filter { ids.insert($0.id).inserted }
      let next = data["offset"] as? String ?? ""
      let serverMore = data["has_more"] as? Bool ?? (data["has_more"] as? Int == 1)
      items = reset ? additions : items + additions
      if serverMore && (next.isEmpty || (!reset && next == offset && additions.isEmpty)) {
        hasMore = false
        error = "动态分页没有返回新内容，请刷新后重试"
      } else {
        offset = next
        hasMore = serverMore
      }
    } catch {
      if token == generation && !(error is CancellationError) {
        self.error = error.localizedDescription
      }
    }
  }
}
struct MobileDynamicCard: View {
  @Bindable var store: Store
  let entry: DynamicEntry
  @State private var gallery: GalleryTarget?
  @State private var comments = false
  @State private var model = Comments()
  @State private var repost = false
  @State private var draft = DynamicDraft()
  @State private var liked = false
  @State private var count = 0
  @State private var initialized = false
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      NavigationLink {
        MobileProfile(store: store, mid: entry.mid)
      } label: {
        HStack {
          MobileAvatar(url: entry.face).frame(width: 36, height: 36).clipShape(.circle)
          VStack(alignment: .leading) {
            Text(entry.author).font(.subheadline.bold())
            Text(entry.date).font(.caption).foregroundStyle(.secondary)
          }
        }
      }.buttonStyle(.plain)
      if !entry.text.isEmpty { Text(entry.text).textSelection(.enabled) }
      if !entry.original.isEmpty {
        Text(entry.original).font(.callout).foregroundStyle(.secondary).padding(12).background(
          .quaternary, in: .rect(cornerRadius: 12))
      }
      if !entry.pictures.isEmpty {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 6) {
          ForEach(entry.pictures, id: \.self) { url in
            Button {
              gallery = GalleryTarget(url: url)
            } label: {
              Thumbnail(url: url).aspectRatio(1, contentMode: .fit).clipShape(
                .rect(cornerRadius: 9))
            }
          }
        }
      }
      if let attachment = entry.attachment {
        VStack(alignment: .leading, spacing: 10) {
          if !attachment.cover.isEmpty {
            Thumbnail(url: attachment.cover).aspectRatio(16 / 9, contentMode: .fit).clipShape(
              .rect(cornerRadius: 12))
          }
          Label(
            attachment.title,
            systemImage: attachment.kind == "直播" ? "dot.radiowaves.left.and.right" : "doc.text"
          ).font(.subheadline.weight(.medium))
          if !attachment.description.isEmpty {
            Text(attachment.description).font(.caption).foregroundStyle(.secondary)
          }
          if let url = attachment.url { Link("查看" + attachment.kind, destination: url) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
          .quaternary, in: .rect(cornerRadius: AppMetrics.itemRadius))
      }
      if entry.text.isEmpty && entry.original.isEmpty && entry.pictures.isEmpty
        && entry.video == nil && entry.attachment == nil
      {
        VStack(alignment: .leading, spacing: 10) {
          Text(entry.unavailableText.isEmpty ? "这条动态暂时无法在应用内展示" : entry.unavailableText).font(
            .callout
          ).foregroundStyle(.secondary)
          Link(
            "查看原动态",
            destination: URL(string: "https://t.bilibili.com")!.appendingPathComponent(entry.id))
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      if let video = entry.video {
        Button {
          store.open(video.bvid)
        } label: {
          MobileVideoCard(video: video)
        }.buttonStyle(.plain)
      }
      HStack(spacing: 18) {
        Button {
          Task { await like() }
        } label: {
          Label("\(count)", systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
        }.disabled(busy || store.account == nil)
        Button {
          repost = true
        } label: {
          Label("\(entry.repostCount)", systemImage: "arrowshape.turn.up.right")
        }.disabled(store.account == nil)
        if entry.commentID > 0 {
          Button {
            comments = true
          } label: {
            Label("\(entry.commentCount)", systemImage: "bubble")
          }
        }
      }.font(.caption).buttonStyle(.borderless).controlSize(.regular)
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }.frame(maxWidth: .infinity, alignment: .leading).onAppear {
      guard !initialized else { return }
      initialized = true
      liked = entry.liked
      count = entry.likeCount
    }
    .sheet(item: $gallery) { MobileGallery(target: $0) }
    .sheet(isPresented: $comments) {
      NavigationStack {
        ScrollView {
          MobileComments(store: store, aid: entry.commentID, model: model, type: entry.commentType)
            .padding()
        }.navigationTitle("动态评论").toolbar { Button("完成") { comments = false } }
      }
    }
    .sheet(isPresented: $repost) {
      MobileDynamicComposer(store: store, draft: draft, repost: entry) {}
    }
  }
  private func like() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      _ = try await store.api.dynamicPost(
        "/x/dynamic/feed/dyn/thumb", ["dyn_id_str": entry.id, "up": liked ? 2 : 1])
      liked.toggle()
      count = max(0, count + (liked ? 1 : -1))
    } catch { self.error = error.localizedDescription }
  }
}
struct MobileDynamicComposer: View {
  @Bindable var store: Store
  @Bindable var draft: DynamicDraft
  var repost: DynamicEntry? = nil
  let published: () -> Void
  @State private var photos: [PhotosPickerItem] = []
  @State private var importing = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        if let repost {
          Section("转发") { Text("@" + repost.author + " " + repost.text).lineLimit(4) }
        }
        Section {
          TextEditor(text: $draft.text).scrollContentBackground(.hidden).padding(10).frame(
            minHeight: 150
          )
          .appGlassEffect(.regular, in: .rect(cornerRadius: AppMetrics.panelRadius))
          HStack {
            EmojiPicker(api: store.api) {
              draft.emotes[$0.token] = $0
              draft.text += $0.token
            }
            if repost == nil {
              PhotosPicker(
                selection: $photos, maxSelectionCount: max(1, 9 - draft.images.count),
                matching: .images
              ) { MobileComposerIcon(name: "photo") }.buttonStyle(.plain)
                .accessibilityLabel("选择动态图片").disabled(draft.images.count >= 9 || importing)
            }
            Spacer()
            Text("\(draft.text.count)/2000").font(.caption)
          }
          ForEach(draft.images, id: \.self) { url in
            HStack {
              Text(url.lastPathComponent.prefix(12))
              Spacer()
              Button("移除") { draft.images.removeAll { $0 == url } }
            }
          }
          Toggle("包含 AI 生成内容", isOn: $draft.aiGenerated)
        }
        if let error = draft.error {
          Section {
            Text(error).foregroundStyle(.red)
            Link("在官网确认发布结果", destination: URL(string: "https://t.bilibili.com/")!)
          }
        }
      }.navigationTitle(repost == nil ? "发布动态" : "转发动态").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button("取消") { dismiss() }.disabled(draft.publishing)
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button(draft.publishing ? "发布中" : "发布") {
              guard let account = store.account else { return }
              Task {
                if await draft.publish(api: store.api, mid: account.mid, repostID: repost?.id) {
                  published()
                  dismiss()
                }
              }
            }.disabled(
              draft.publishing || importing || draft.text.count > 2000
                || (draft.text.isEmpty && draft.images.isEmpty && repost == nil))
          }
        }
        .interactiveDismissDisabled(draft.publishing)
        .onChange(of: photos) { _, items in
          Task {
            importing = true
            defer {
              importing = false
              photos = []
            }
            do {
              for item in items where draft.images.count < 9 {
                draft.images.append(try await importPhoto(item))
              }
            } catch { draft.error = error.localizedDescription }
          }
        }
    }.presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationCornerRadius(24)
  }
}
struct MobileConversationSheet: View {
  @Bindable var store: Store
  let conversation: Conversation
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      MobileConversation(store: store, conversation: conversation)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("关闭") { dismiss() }.accessibilityLabel("关闭会话")
          }
        }
    }
    .fullScreenCover(isPresented: $store.showPlayer) { MobilePlayerPage(store: store) }
    .sheet(
      isPresented: Binding(
        get: { store.showLogin && !store.showPlayer }, set: { store.showLogin = $0 }),
      onDismiss: { store.closeLogin() }
    ) { MobileLogin(store: store) }
    .sheet(
      item: Binding(
        get: { store.showPlayer ? nil : store.webTarget }, set: { store.webTarget = $0 })
    ) { MobileWebPage(store: store, target: $0) }
    .presentationDetents([.fraction(0.65), .large])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(24)
  }
}

struct MobileConversation: View {
  @Bindable var store: Store
  let conversation: Conversation
  var model: InboxModel? = nil
  private var inbox: InboxModel { model ?? store.inbox }
  @State private var photo: PhotosPickerItem?
  @State private var imageDraft: URL?
  @State private var error: String?
  @State private var gallery: GalleryTarget?
  @State private var scrollID: String?
  @State private var started = false
  var body: some View {
    @Bindable var inbox = inbox
    VStack(spacing: 0) {
      ConversationTimeline(store: store, model: inbox) { message in messageRow(message) }
        .id(conversation.id)
      if let error = error ?? inbox.messageError {
        HStack {
          Text(error).font(.caption).foregroundStyle(.red)
          Button("重试") { Task { await inbox.loadMessages(api: store.api) } }
            .disabled(inbox.loadingMessages)
        }.padding(12)
      }
      if !conversation.system {
        VStack(spacing: 8) {
          if let imageDraft {
            HStack {
              Text("已选择图片").font(.caption)
              Button("取消") { self.imageDraft = nil }
              Spacer()
              Button("发送图片") {
                guard let account = store.account else { return }
                Task {
                  if await inbox.sendImage(imageDraft, api: store.api, account: account) {
                    self.imageDraft = nil
                  }
                }
              }.disabled(inbox.sending)
            }
          }
          AppGlassContainer(spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
              EmojiPicker(api: store.api) { emote in
                inbox.emotes[emote.token] = emote
                inbox.drafts[conversation.id, default: ""] += emote.token
              }
              PhotosPicker(selection: $photo, matching: .images) {
                MobileComposerIcon(name: "photo")
              }
              .buttonStyle(.plain).accessibilityLabel("选择消息图片")
              TextField(
                "发送消息",
                text: Binding(
                  get: { inbox.drafts[conversation.id] ?? "" },
                  set: { inbox.drafts[conversation.id] = $0 }), axis: .vertical
              ).lineLimit(1...5).textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 44)
                .appGlassEffect(.regular, in: .rect(cornerRadius: AppMetrics.panelRadius))
                .accessibilityIdentifier("message-input")
              Button {
                guard let account = store.account else { return }
                Task { await inbox.send(api: store.api, account: account) }
              } label: {
                Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold))
                  .foregroundStyle(.white).frame(width: 44, height: 44)
                  .appGlassEffect(.regular.tint(biliPink).interactive(), in: .circle)
              }.buttonStyle(.plain).accessibilityLabel("发送").disabled(
                inbox.sending
                  || (inbox.drafts[conversation.id] ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty)
            }
          }
        }.padding(12)
      }
    }.background(MobileSurface.background).navigationTitle(conversation.name)
      .navigationBarTitleDisplayMode(.inline)
      .task(id: conversation.id) {
        inbox.select(conversation)
        await inbox.loadMessages(api: store.api)
        if !started {
          scrollID = inbox.messages.last?.id
          started = true
        }
      }
      .onChange(of: photo) { _, item in
        guard let item else { return }
        Task {
          do { imageDraft = try await importPhoto(item) } catch {
            self.error = error.localizedDescription
          }
          photo = nil
        }
      }
      .sheet(item: $gallery) { MobileGallery(target: $0) }
  }
  private func messageRow(_ message: PrivateMessage) -> some View {
    HStack {
      if message.sender == store.account?.mid { Spacer(minLength: 36) }
      VStack(alignment: .leading, spacing: 7) {
        if let picture = message.image {
          Button {
            gallery = GalleryTarget(url: picture)
          } label: {
            Thumbnail(url: picture, mode: .fit, placeholder: "photo").frame(width: 210, height: 180)
          }.accessibilityLabel("查看消息图片")
        } else if let share = message.share {
          Button {
            Task {
              do {
                if share.isVideo {
                  store.open(try await share.resolveVideo(api: store.api))
                } else if let url = share.url {
                  await UIApplication.shared.open(url)
                }
              } catch { self.error = error.localizedDescription }
            }
          } label: {
            VStack(alignment: .leading) {
              Thumbnail(url: share.cover).frame(width: 210, height: 118)
              Text(share.title).font(.subheadline)
            }
          }.buttonStyle(.plain)
        } else {
          CommentText(
            content: CommentTextContent(message: message.text, emotes: inbox.emotes),
            copyTitle: "复制消息")
        }
        Text(message.date.formatted(AppDateFormat.timestamp)).font(.caption2).foregroundStyle(
          .secondary)
      }.padding(12).background(
        message.sender == store.account?.mid
          ? biliPink.opacity(0.12) : Color.secondary.opacity(0.1), in: .rect(cornerRadius: 16)
      )
      .contextMenu {
        Button("复制") { UIPasteboard.general.string = message.text }
        if inbox.canRecall(message, accountID: store.account?.mid ?? 0) {
          Button("撤回", role: .destructive) {
            guard let account = store.account else { return }
            Task { await inbox.recall(message, api: store.api, account: account) }
          }
        }
      }
      if message.sender != store.account?.mid { Spacer(minLength: 36) }
    }
  }
}
struct MobileNotifications: View {
  @Bindable var store: Store
  let kind: Int
  @State private var commentNotice: NativeNotice?
  @State private var rows: [NativeNotice] = []
  @State private var cursor: [String: Any] = [:]
  @State private var loading = false
  @State private var more = true
  @State private var error: String?
  @State private var generation = UUID()
  var body: some View {
    List {
      if store.account == nil {
        ContentUnavailableView {
          Label("登录后查看互动", systemImage: "bubble.left.and.bubble.right")
        } actions: {
          Button("登录") { store.login() }
        }
      }
      ForEach(rows) { row in
        HStack(alignment: .top, spacing: 12) {
          MobileAvatar(url: row.face).frame(width: 44, height: 44)
          VStack(alignment: .leading, spacing: 8) {
            Text(row.headline).font(.subheadline.weight(.semibold))
            if row.date.timeIntervalSince1970 > 0 {
              Text(row.date, format: .dateTime.month().day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
            }
            if !row.text.isEmpty { Text(row.text).font(.body).textSelection(.enabled) }
            if !row.quote.isEmpty {
              Text(row.quote).font(.subheadline).foregroundStyle(.secondary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 12))
            }
            if row.commentTarget != nil {
              Button("查看并回复") { commentNotice = row }.buttonStyle(.borderless).frame(minHeight: 44)
            }
            if row.commentTarget == nil, let url = row.originalPageURL {
              Button("查看内容") {
                if let bvid = videoID(url.absoluteString) {
                  store.open(bvid)
                } else {
                  store.webTarget = WebTarget(url: url, title: "消息内容")
                }
              }.buttonStyle(.borderless).frame(minHeight: 44)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 8)
      }
      if loading { ProgressView("正在加载互动") }
      if let error { MobileError(text: error) { Task { await load(reset: rows.isEmpty) } } }
      if store.account != nil && !loading && rows.isEmpty && error == nil {
        ContentUnavailableView("暂无互动消息", systemImage: "bubble.left.and.bubble.right")
      }
      if store.account != nil && more && !loading && error == nil {
        Button("加载更多") { Task { await load() } }
      }
    }.sheet(item: $commentNotice) { MobileNoticeComment(store: store, notice: $0) }
      .listStyle(.plain).task(id: store.account?.mid) { await load(reset: true) }
      .refreshable { await load(reset: true) }
  }
  private func load(reset: Bool = false) async {
    if reset {
      generation = UUID()
      loading = false
      more = true
    }
    guard store.account != nil else {
      rows = []
      cursor = [:]
      error = nil
      return
    }
    guard !loading, more else { return }
    let token = generation
    loading = true
    error = nil
    defer { if token == generation { loading = false } }
    let endpoint = kind == 1 ? "reply" : kind == 2 ? "at" : "like"
    var query = ["platform": "web", "mobi_app": "web"]
    if !reset {
      if let id = cursor["id"] { query["id"] = String(describing: id) }
      if let time = cursor["time"] { query[endpoint + "_time"] = String(describing: time) }
    }
    do {
      let data = try await store.api.request("/x/msgfeed/" + endpoint, query)
      try Task.checkCancellation()
      guard token == generation else { return }
      let total = data["total"] as? [String: Any] ?? data
      let latest = data["latest"] as? [String: Any] ?? [:]
      let raw =
        (reset ? latest["items"] as? [[String: Any]] ?? [] : [])
        + (total["items"] as? [[String: Any]] ?? [])
      var ids = Set(reset ? [] : rows.map(\.id))
      let result = raw.compactMap { NativeNotice.parse($0, kind: kind) }.filter { ids.insert($0.id).inserted }
      rows = reset ? result : rows + result
      cursor = total["cursor"] as? [String: Any] ?? [:]
      more = cursor["is_end"] as? Bool == false
      if reset { await store.messageUnread.refresh(api: store.api) }
    } catch {
      if token == generation && !(error is CancellationError) {
        self.error = error.localizedDescription
      }
    }
  }
}
