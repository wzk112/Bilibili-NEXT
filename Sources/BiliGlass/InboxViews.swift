import SwiftUI

struct NativeInboxPage: View {
  @Bindable var store: Store
  @State private var tab = 0
  @State private var query = ""
  @State private var imageDrafts: [String: URL] = [:]
  var body: some View {
    @Bindable var inbox = store.inbox
    VStack(spacing: 16) {
      HStack {
        Text("消息").font(.title2.bold())
        Spacer()
        Picker("消息分类", selection: $tab) {
          Text(categoryTitle("私信", kind: 0)).tag(0)
          Text(categoryTitle("回复我的", kind: 1)).tag(1)
          Text(categoryTitle("@ 我的", kind: 2)).tag(2)
          Text(categoryTitle("收到的赞", kind: 3)).tag(3)
          Text("系统通知").tag(4)
        }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 600)
      }.padding(18).floatingGlass(AppLayout.panelRadius)
      if let error = store.messageUnread.error {
        HStack { Text(error).font(.caption).foregroundStyle(.secondary); Button("重试") { Task { await store.messageUnread.refresh(api: store.api) } } }
      }
      if store.account == nil {
        ContentUnavailableView {
          Label("登录后查看消息", systemImage: "envelope")
        } actions: {
          Button("登录") { store.login() }.buttonStyle(.glass)
        }
      } else if [1, 2, 3].contains(tab) {
        NativeNotificationsPage(store: store, kind: tab)
      } else {
        HStack(spacing: 16) {
          conversationList.frame(width: 245)
          conversation.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }.task(id: String(store.account?.mid ?? 0) + ":" + String(tab == 4)) {
      guard store.account != nil else { return }
      await inbox.load(api: store.api, systemOnly: tab == 4)
      await store.messageUnread.refresh(api: store.api)
    }
  }
  private func categoryTitle(_ title: String, kind: Int) -> String {
    let count = store.messageUnread.counts[kind]
    return count > 0 ? title + " (\(count > 99 ? "99+" : String(count)))" : title
  }
  private var conversationList: some View {
    let inbox = store.inbox
    return VStack(spacing: 12) {
      HStack {
        TextField("搜索会话", text: $query).textFieldStyle(.plain)
        Button {
          Task { await inbox.load(api: store.api, systemOnly: tab == 4) }
        } label: {
          Image(systemName: "arrow.clockwise")
        }.buttonStyle(.plain).help("刷新消息")
      }.padding(13).appGlass(AppLayout.itemRadius).padding(.horizontal, 12)
        .padding(.top, 12)
      if let error = inbox.error {
        Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14)
      }
      ScrollView {
        LazyVStack(spacing: 5) {
          ForEach(
            inbox.conversations.filter {
              (tab != 4 || $0.system)
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
            }
          ) { row in
            Button {
              inbox.select(row)
            } label: {
              HStack(alignment: .top, spacing: 10) {
                Thumbnail(url: row.face, mode: .fill, placeholder: "person.crop.circle.fill").frame(
                  width: 36, height: 36
                ).clipShape(
                  Circle())
                VStack(alignment: .leading, spacing: 5) {
                  HStack {
                    Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 1)
                    if row.unread > 0 {
                      Text(row.unread > 99 ? "99+" : String(row.unread)).font(.caption2)
                        .foregroundStyle(.white).padding(4).background(biliPink, in: .capsule)
                    }
                  }
                  Text(row.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .multilineTextAlignment(.leading)
                }
              }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                  inbox.selected?.id == row.id ? biliPink.opacity(0.16) : .clear,
                  in: .rect(cornerRadius: AppLayout.itemRadius))
            }.buttonStyle(.plain)
          }
          if inbox.loading {
            ProgressView().controlSize(.small).padding(12)
          } else if inbox.hasMore {
            Button("加载更多会话") {
              Task { await inbox.load(api: store.api, more: true, systemOnly: tab == 4) }
            }.buttonStyle(.glass).padding(12)
          }
        }.padding(.horizontal, 8).padding(.bottom, 12)
      }
    }.floatingGlass(AppLayout.panelRadius).clipShape(RoundedRectangle(cornerRadius: AppLayout.panelRadius))
  }
  @ViewBuilder private var conversation: some View {
    let inbox = store.inbox
    if let selected = inbox.selected {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Button {
            store.showProfile(selected.mid)
          } label: {
            HStack {
              Thumbnail(url: selected.face, mode: .fill, placeholder: "person.crop.circle.fill")
                .frame(width: 30, height: 30).clipShape(
                  Circle())
              Text(selected.name).font(.headline)
            }
          }.buttonStyle(.plain)
          Spacer()
          Button {
            Task { await inbox.loadMessages(api: store.api) }
          } label: {
            Image(systemName: "arrow.clockwise")
          }.buttonStyle(.glass).help("刷新会话")
        }.padding(16)
        Divider().padding(.horizontal, 16)
        ConversationTimeline(store: store) { message in
          messageBubble(message, own: message.sender == store.account?.mid)
        }.id(selected.id)
        if let error = inbox.messageError {
          HStack {
            Text(error).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("验证登录") {
              store.webTarget = WebTarget(
                url: URL(string: "https://message.bilibili.com/#/whisper")!, title: "消息验证")
            }.buttonStyle(.glass)
          }.padding(12)
        }
        Divider().padding(.horizontal, 16)
        HStack {
          EmojiPicker(api: store.api) { emote in inbox.emotes[emote.token] = emote; inbox.drafts[selected.id, default: ""] += emote.token }
          Button { if let url = ImageAttachment.choose().first { imageDrafts[selected.id] = url } } label: { Image(systemName: "photo.badge.plus") }.buttonStyle(.glass).help("发送图片").accessibilityLabel("添加私信图片")
          if let image = imageDrafts[selected.id] {
            Text(image.lastPathComponent).font(.caption).lineLimit(1)
            Button("取消图片") { imageDrafts[selected.id] = nil }.buttonStyle(.plain)
            Button("发送图片") { Task { if let account = store.account, await inbox.sendImage(image, api: store.api, account: account) { imageDrafts[selected.id] = nil } } }.buttonStyle(.glassProminent)
          }
          Spacer()
        }.padding(.horizontal, 14).padding(.top, 10).disabled(inbox.sending)
        HStack(alignment: .bottom, spacing: 12) {
          TextField(
            "发送私信",
            text: Binding(
              get: { inbox.drafts[selected.id] ?? "" }, set: { inbox.drafts[selected.id] = $0 }),
            axis: .vertical
          )
          .lineLimit(2...6).textFieldStyle(.plain).padding(12).appGlass(AppLayout.itemRadius)
          Button(inbox.sending ? "发送中" : "发送") {
            if let account = store.account {
              Task { await inbox.send(api: store.api, account: account) }
            }
          }
          .buttonStyle(.glassProminent).disabled(
            inbox.sending
              || (inbox.drafts[selected.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
          )
        }.padding(14)
      }.floatingGlass(AppLayout.panelRadius).clipShape(RoundedRectangle(cornerRadius: AppLayout.panelRadius)).task(id: selected.id) {
        await inbox.loadMessages(api: store.api)
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(15)) } catch { return }
          await inbox.loadMessages(api: store.api)
        }
      }
    } else {
      ContentUnavailableView("选择一个会话", systemImage: "bubble.left.and.bubble.right").frame(
        maxWidth: .infinity, maxHeight: .infinity
      ).floatingGlass(AppLayout.panelRadius)
    }
  }
  @ViewBuilder private func messageBubble(_ message: PrivateMessage, own: Bool) -> some View {
    if message.isNotice || message.retracted {
      Text(message.text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        .textSelection(.enabled).padding(.horizontal, 24).padding(.vertical, 8).frame(maxWidth: .infinity)
    } else {
    HStack {
      if own { Spacer(minLength: 50) }
      VStack(alignment: .leading, spacing: 8) {
        if let image = message.image {
          Button { store.imageGallery = ImageGalleryTarget(urls: [image], selected: 0) } label: {
            Thumbnail(url: image, mode: .fit).frame(width: 220, height: 180).clipShape(
              RoundedRectangle(cornerRadius: AppLayout.mediaRadius))
          }.buttonStyle(.plain).help("查看图片")
        }
        if let share = message.share {
          MessageShareCard(share: share, store: store)
        } else {
        CommentText(content: CommentTextContent(message: message.text, emotes: store.inbox.emotes), copyTitle: "复制消息").foregroundStyle(
          message.retracted ? .secondary : .primary
        ).fixedSize(horizontal: false, vertical: true)
        if let bvid = message.video {
          Button("播放视频") { store.open(bvid) }.buttonStyle(.glass)
        } else if let link = message.link, message.image == nil {
          Link("查看详情", destination: link).font(.caption)
        }
        }
        Text(message.date.formatted(AppDateFormat.timestamp)).font(.caption2)
          .foregroundStyle(.secondary)
      }.padding(14).appGlass(AppLayout.itemRadius, tint: own ? biliPink.opacity(0.12) : .clear)
        .contextMenu {
          Button("复制消息") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
          if let account = store.account, inboxCanRecall(message, accountID: account.mid) {
            Button("撤回") { Task { await store.inbox.recall(message, api: store.api, account: account) } }.disabled(store.inbox.sending)
          }
        }
      if !own { Spacer(minLength: 50) }
    }
    }
  }
  private func inboxCanRecall(_ message: PrivateMessage, accountID: Int) -> Bool { store.inbox.canRecall(message, accountID: accountID) }
}

struct NativeNotificationsPage: View {
  @Bindable var store: Store
  let kind: Int
  @State private var rows: [NativeNotice] = []
  @State private var cursor: [String: Any] = [:]
  @State private var hasMore = false
  @State private var loading = false
  @State private var error: String?
  @State private var identity = UUID()
  @State private var focusedNotice: NativeNotice?
  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        if let error { ErrorBanner(text: error) { Task { await load(reset: true) } } }
        ForEach(rows) { notice in
          HStack(alignment: .top, spacing: 0) {
            Button {
              store.showProfile(notice.mid)
            } label: {
              Thumbnail(url: notice.face, mode: .fill, placeholder: "person.crop.circle.fill")
                .frame(width: 38, height: 38).clipShape(
                  Circle())
            }.buttonStyle(.plain).padding(.leading, 20).padding(.top, 20)
              .help("查看用户")
            Button { open(notice) } label: {
              VStack(alignment: .leading, spacing: 10) {
              Text(notice.headline).font(.headline)
              if !notice.text.isEmpty { Text(notice.text) }
              if !notice.quote.isEmpty {
                Text(notice.quote).font(.callout).foregroundStyle(.secondary).lineLimit(4)
              }
              HStack {
                Text(notice.date.formatted(AppDateFormat.timestamp)).font(.caption)
                  .foregroundStyle(.secondary)
                Spacer()
                if notice.commentTarget != nil {
                  Label("查看并回复", systemImage: "chevron.right").font(.callout)
                } else if notice.originalPageURL != nil {
                  Label("查看原内容", systemImage: "chevron.right").font(.callout)
                }
              }
              }.multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 20).padding(.leading, 14).padding(.trailing, 20)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
              .disabled(notice.commentTarget == nil && notice.originalPageURL == nil)
              .contextMenu {
                Button("复制消息") {
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString([notice.headline, notice.text, notice.quote].filter { !$0.isEmpty }.joined(separator: "\n"), forType: .string)
                }
              }
          }.frame(maxWidth: .infinity, alignment: .leading).floatingGlass(AppLayout.panelRadius)
        }
        if loading {
          ProgressView().frame(maxWidth: .infinity).padding(20)
        } else if hasMore {
          Button("加载更多") { Task { await load(reset: false) } }.buttonStyle(.glass).frame(
            maxWidth: .infinity)
        } else if rows.isEmpty && error == nil {
          ContentUnavailableView("暂无消息", systemImage: "bell").frame(maxWidth: .infinity)
        }
      }.padding(AppLayout.pageInset)
    }.task(id: "\(kind):\(store.account?.mid ?? 0)") { await load(reset: true) }
      .refreshable { await load(reset: true) }
      .sheet(item: $focusedNotice) { notice in
        NativeNoticeComment(store: store, notice: notice)
      }
  }
  private func open(_ notice: NativeNotice) {
    if notice.commentTarget != nil {
      focusedNotice = notice
    } else if let url = notice.originalPageURL {
      if let bvid = videoID(url.absoluteString) { store.open(bvid) }
      else { NSWorkspace.shared.open(url) }
    }
  }
  private func load(reset: Bool) async {
    if reset {
      identity = UUID()
      rows = []
      cursor = [:]
    } else if loading {
      return
    }
    let token = identity
    loading = true
    error = nil
    defer { if token == identity { loading = false } }
    do {
      let endpoint = kind == 1 ? "reply" : kind == 2 ? "at" : "like"
      var query = ["platform": "web", "mobi_app": "web"]
      if !reset {
        if let id = cursor["id"] { query["id"] = String(describing: id) }
        if let time = cursor["time"] { query[endpoint + "_time"] = String(describing: time) }
      }
      let data = try await store.api.request("/x/msgfeed/" + endpoint, query)
      try Task.checkCancellation()
      guard token == identity else { return }
      let total = data["total"] as? [String: Any] ?? data
      let latest = data["latest"] as? [String: Any] ?? [:]
      let raw =
        (reset ? latest["items"] as? [[String: Any]] ?? [] : [])
        + (total["items"] as? [[String: Any]] ?? [])
      var ids = Set(rows.map(\.id))
      rows += raw.compactMap { NativeNotice.parse($0, kind: kind) }.filter { ids.insert($0.id).inserted }
      cursor = total["cursor"] as? [String: Any] ?? [:]
      hasMore = cursor["is_end"] as? Bool == false
      // Loading the first page updates the service-side last-view cursor. Re-query, never guess zero.
      if reset { await store.messageUnread.refresh(api: store.api) }
    } catch {
      if token == identity && !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}

struct NativeNoticeComment: View {
  @Bindable var store: Store
  let notice: NativeNotice
  @State private var comments = Comments()
  @State private var retry = 0
  @State private var originalPage: WebTarget?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("评论回复").font(.title2.bold())
        Spacer()
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            if comments.loading { ProgressView("正在定位评论").frame(maxWidth: .infinity) }
            if let target = notice.commentTarget {
              ForEach(comments.items) { reply in
                Text("消息中的评论").font(.caption).foregroundStyle(.secondary)
                ReplyRow(reply: reply, store: store, aid: target.oid, comments: comments)
                  .accessibilityIdentifier("focused-comment")
              }
              if !comments.focusedReplies.isEmpty {
                Divider()
                Text("同一条评论下的回复").font(.headline)
                ForEach(comments.focusedReplies) { reply in
                  ReplyRow(reply: reply, store: store, aid: target.oid, comments: comments)
                  Divider()
                }
              }
              if let root = comments.focusedRoot {
                if let error = comments.childErrors[root.id] { Text(error).font(.caption).foregroundStyle(.secondary) }
                if comments.childHasMore[root.id] != false {
                  Button(comments.childLoading.contains(root.id) ? "加载中" : "加载更多回复") {
                    Task { await comments.children(root, aid: target.oid, api: store.api, pageSize: 49) }
                  }.disabled(comments.childLoading.contains(root.id)).buttonStyle(.glass)
                }
              }
            }
            CommentSubmissionReceipt(comments: comments).id("submission")
            if let error = comments.error { ErrorBanner(text: error) { retry += 1 } }
            if let url = notice.originalPageURL {
              Button("查看原页面") { originalPage = WebTarget(url: url, title: "原页面") }.buttonStyle(.glass)
            }
          }.padding(4)
        }.onChange(of: comments.sending) {
          if !comments.sending, comments.submittedText != nil { reader.scrollTo("submission", anchor: .bottom) }
        }
      }
    }.padding(22).frame(width: 720, height: 620).background { GlassBackdrop() }
      .task(id: retry) {
        if let target = notice.commentTarget { _ = await comments.loadFocused(target, api: store.api) }
      }
      .sheet(isPresented: Binding(get: { comments.replyingTo != nil }, set: { if !$0 { comments.replyingTo = nil } })) {
        if let target = notice.commentTarget {
          MacReplyComposerSheet(store: store, aid: target.oid, comments: comments, verificationURL: notice.originalPageURL)
        }
      }
      .sheet(item: $originalPage) { target in CommentOriginalPage(store: store, target: target) }
  }
}
