import SwiftUI

struct CommentsView: View {
  @Bindable var store: Store
  let aid: Int
  let resourceType: Int
  let model: Comments?
  let verificationURL: URL?
  init(store: Store, aid: Int, type: Int = 1, model: Comments? = nil, verificationURL: URL? = nil) {
    self.store = store
    self.aid = aid
    resourceType = type
    self.model = model
    self.verificationURL = verificationURL
  }
  var body: some View {
    @Bindable var comments = model ?? store.comments
    LazyVStack(alignment: .leading, spacing: 20) {
      HStack {
        Text("评论").font(.title2.bold())
        Text("\(comments.count)").foregroundStyle(.secondary)
        if !comments.items.isEmpty { Text("已加载 \(comments.items.count) 个主楼").font(.caption).foregroundStyle(.tertiary) }
        Spacer()
        Picker("排序", selection: $comments.sort) {
          Text("最热").tag(1)
          Text("最新").tag(0)
        }.labelsHidden().pickerStyle(.segmented).frame(width: 150).onChange(of: comments.sort) {
          comments.load(aid: aid, type: resourceType, api: store.api)
        }
      }
      MacCommentComposer(store: store, aid: aid, comments: comments, verificationURL: verificationURL)
      CommentSubmissionReceipt(comments: comments)
      ForEach(comments.items) { reply in
        VStack(alignment: .leading, spacing: 12) {
          ReplyRow(reply: reply, store: store, aid: aid, comments: comments)
          let children = comments.expanded[reply.id] ?? reply.children
          ForEach(children) { child in
            ReplyRow(reply: child, store: store, aid: aid, comments: comments).padding(.leading, 44)
          }
          if reply.count > children.count && comments.childHasMore[reply.id] != false {
            Button(comments.childLoading.contains(reply.id) ? "加载回复中…" : comments.expanded[reply.id] == nil ? "展开回复（\(reply.count)）" : "加载更多回复") {
              Task { await comments.children(reply, aid: aid, api: store.api) }
            }.buttonStyle(.plain).foregroundStyle(.primary).fontWeight(.medium).padding(.leading, 44).disabled(
              comments.childLoading.contains(reply.id))
          }
          if let error = comments.childErrors[reply.id] {
            Text(error).font(.caption).foregroundStyle(.secondary).padding(.leading, 44)
          }
          if comments.expanded[reply.id] != nil {
            Button("收起回复") { comments.collapse(reply) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 44)
          }
          Divider()
        }.id(reply.id)
      }
      LoadMoreFooter(loading: comments.loading, hasMore: comments.hasMore, error: comments.error,
                     count: comments.items.count, title: "加载更多评论") {
        comments.load(aid: aid, type: resourceType, api: store.api, more: !comments.items.isEmpty)
      }
      if !comments.loading && comments.items.isEmpty && comments.error == nil {
        Text("还没有评论").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(20)
      }
    }.scrollTargetLayout()
      .task(id: "\(resourceType):\(aid)") { comments.loadIfNeeded(aid: aid, type: resourceType, api: store.api) }
      .sheet(isPresented: Binding(get: { comments.replyingTo != nil }, set: { if !$0 { comments.replyingTo = nil } })) {
        MacReplyComposerSheet(store: store, aid: aid, comments: comments, verificationURL: verificationURL)
      }
  }
}
struct MacCommentComposer: View {
  @Bindable var store: Store
  let aid: Int
  @Bindable var comments: Comments
  var verificationURL: URL? = nil
  var focusOnAppear = false
  @FocusState private var inputFocused: Bool
  @State private var verificationPage: WebTarget?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let target = comments.replyingTo {
        HStack {
          Text("回复 @" + target.name).font(.callout)
          Spacer()
          Button("取消回复") { comments.replyingTo = nil }.disabled(comments.sending)
        }
      }
      HStack(alignment: .bottom) {
        TextField(store.account == nil ? "登录后发表评论" : "发表评论", text: $comments.draft, axis: .vertical)
          .accessibilityIdentifier("comment-draft").focused($inputFocused)
          .lineLimit(2...5).textFieldStyle(.plain).padding(10).appGlass(12).disabled(
            store.account == nil || comments.sending)
        Button(comments.sending ? "发送中" : "发送") {
          if store.account == nil {
            store.login()
          } else {
            Task { await comments.send(aid: aid, api: store.api) }
          }
        }.buttonStyle(.glassProminent).disabled(
          comments.sending || comments.draft.count > 1000
            || (store.account != nil
              && comments.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && comments.attachments.isEmpty)
        )
      }
      if comments.draft.count > 1000 { Text("评论最多 1000 字").foregroundStyle(.red).font(.caption) }
      HStack {
        EmojiPicker(api: store.api) { comments.draft += $0.token }
        Button { comments.attachments += ImageAttachment.choose(multiple: true).prefix(max(0, 9 - comments.attachments.count)) } label: { Label("添加图片", systemImage: "photo.badge.plus") }.buttonStyle(.glass).disabled(comments.attachments.count >= 9)
        Spacer()
      }.disabled(store.account == nil || comments.sending)
      if !comments.attachments.isEmpty { AttachedImages(urls: $comments.attachments).disabled(comments.sending) }

      if let error = comments.sendError {
        HStack {
          Text(error).foregroundStyle(.red).font(.callout)
          Button("完成验证") {
            let target =
              verificationURL
              ?? store.playback.detail.map {
                URL(string: "https://www.bilibili.com/video/" + $0.video.bvid)!
              }
            if let target {
              verificationPage = WebTarget(url: target, title: "评论与验证")
            }
          }
        }
      }
    }
    .task { if focusOnAppear { inputFocused = true } }
    .sheet(item: $verificationPage) { target in
      CommentOriginalPage(store: store, target: target)
    }
  }
}

struct CommentSubmissionReceipt: View {
  @Bindable var comments: Comments
  var body: some View {
      if let submitted = comments.submittedText, let status = comments.submissionStatus {
        HStack(alignment: .top, spacing: 12) {
          Image(systemName: "paperplane").foregroundStyle(biliPink)
          VStack(alignment: .leading, spacing: 6) {
            Text(status).font(.callout.weight(.medium))
            Text(submitted).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("这是本次提交记录，公开显示以服务端为准。").font(.caption).foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
          Button { comments.submittedText = nil; comments.submissionStatus = nil } label: {
            Image(systemName: "xmark")
          }.buttonStyle(.plain).help("收起提交记录")
        }.padding(14).appGlass(14)
      }
  }
}

struct MacReplyComposerSheet: View {
  @Bindable var store: Store
  let aid: Int
  @Bindable var comments: Comments
  var verificationURL: URL? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("回复评论").font(.title2.bold())
        Spacer()
        Button("收起") { comments.replyingTo = nil }.disabled(comments.sending)
          .keyboardShortcut(.cancelAction)
      }
      if let target = comments.replyingTo {
        CommentText(content: target.textContent).lineLimit(4)
          .font(.callout).foregroundStyle(.secondary)
      }
      Divider()
      ScrollView {
        MacCommentComposer(store: store, aid: aid, comments: comments,
          verificationURL: verificationURL, focusOnAppear: true)
      }
    }.padding(22).frame(width: 600, height: 440)
      .background { GlassBackdrop() }.interactiveDismissDisabled(comments.sending)
  }
}

struct CommentOriginalPage: View {
  @Bindable var store: Store
  let target: WebTarget
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(spacing: 0) {
      HStack { Text(target.title); Spacer(); Button("完成") { dismiss() } }.padding()
      OfficialWebPanel(target: target, api: store.api)
    }.frame(minWidth: 900, minHeight: 650)
  }
}

struct ReplyRow: View {
  let reply: Reply
  @Bindable var store: Store
  let aid: Int
  let comments: Comments
  @State private var expandedText = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Button {
        store.showProfile(reply.mid)
      } label: {
        Thumbnail(url: reply.face, mode: .fill, placeholder: "person.crop.circle.fill").frame(
          width: 34, height: 34
        ).clipShape(Circle())
      }.buttonStyle(.plain)
      VStack(alignment: .leading, spacing: 8) {
        Button(reply.name) { store.showProfile(reply.mid) }.buttonStyle(
          .plain
        ).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
        CommentText(content: reply.textContent).lineLimit(expandedText ? nil : 8)
          .fixedSize(horizontal: false, vertical: true)
        if reply.message.count > 350 || reply.message.split(separator: "\n").count > 8 {
          Button(expandedText ? "收起" : "展开全文") { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expandedText.toggle() } }.font(.caption).buttonStyle(
            .plain
          ).foregroundStyle(.primary).fontWeight(.medium)
        }
        ForEach(reply.videoLinks, id: \.url) { link in
          CommentVideoCard(link: link, store: store)
        }
        if !reply.pictures.isEmpty {
          ScrollView(.horizontal) {
            HStack {
              ForEach(Array(reply.pictures.enumerated()), id: \.offset) { index, image in
                Button {
                  store.imageGallery = ImageGalleryTarget(urls: reply.pictures, selected: index)
                } label: {
                  Thumbnail(url: image, mode: .fill).frame(width: 140, height: 105)
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay(alignment: .bottomTrailing) {
                      Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                        .padding(6).glassEffect(.clear, in: .circle).padding(6)
                    }
                }.buttonStyle(.plain).help("查看图片").accessibilityLabel("查看评论图片 \(index+1)")
              }
            }
          }
        }
        HStack(spacing: 14) {
          Text(reply.date.formatted(AppDateFormat.timestamp))
          if !reply.location.isEmpty { Text(reply.location) }
          Button {
            Task { await comments.like(reply, aid: aid, api: store.api) }
          } label: {
            Label(
              reply.likes > 0 ? "\(reply.likes)" : "赞",
              systemImage: reply.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
          }.buttonStyle(.plain)
          Button("回复") { comments.replyingTo = reply }.buttonStyle(.plain)
          if reply.mid == store.account?.mid {
            Menu {
              Button("删除评论", role: .destructive) {
                Task {
                  do {
                    _ = try await store.api.post(
                      "/x/v2/reply/del",
                      [
                        "type": String(comments.resourceType), "oid": "\(aid)",
                        "rpid": "\(reply.id)",
                      ])
                    comments.load(aid: aid, type: comments.resourceType, api: store.api)
                  } catch { comments.sendError = error.localizedDescription }
                }
              }
            } label: {
              Image(systemName: "ellipsis")
            }.menuStyle(.borderlessButton).frame(width: 20)
          }
        }.font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
struct ProfilePage: View {
  @Bindable var store: Store
  let mid: Int
  @State private var spaceSheet: SpaceSheet?
  @State private var profile: Profile?
  @State private var videos: [Video] = []
  @State private var page = 1
  @State private var loading = false
  @State private var changingFollow = false
  @State private var error: String?
  @State private var hasMore = true
  @State private var identity = UUID()
  private var ownProfile: Bool { mid == store.account?.mid }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        if let p = profile {
          header(p)
        } else if loading {
          ProgressView("正在加载个人资料").frame(maxWidth: .infinity).padding(30)
        }
        if ownProfile { personalActions }
        HStack(spacing: 12) {
          Text("投稿").font(.title2.bold())
          if let p = profile { Text("\(p.videos)").foregroundStyle(.secondary) }
          Spacer()
          Button {
            spaceSheet = SpaceSheet(mid: mid, kind: .dynamic)
          } label: {
            Label("动态", systemImage: "rectangle.stack")
          }
          Button {
            spaceSheet = SpaceSheet(mid: mid, kind: .collections)
          } label: {
            Label("合集", systemImage: "square.stack")
          }
          Button {
            Task { await load(reset: true) }
          } label: {
            Image(systemName: "arrow.clockwise")
          }.disabled(loading).help("刷新个人主页")
        }.buttonStyle(.glass).padding(16).floatingGlass()
        if let error {
          ErrorBanner(text: error) { Task { await load(reset: true) } }
          Button("打开官方主页") {
            NSWorkspace.shared.open(URL(string: "https://space.bilibili.com/\(mid)")!)
          }.buttonStyle(.glass)
        }
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 235, maximum: 390), spacing: 18)], spacing: 20
        ) {
          ForEach(videos) { v in
            Button {
              store.profileTarget = nil
              store.open(v.bvid)
            } label: {
              VideoCard(video: v)
            }.buttonStyle(.plain)
          }
        }
        if !videos.isEmpty {
          LoadMoreFooter(loading: loading, hasMore: hasMore, error: error, count: videos.count, title: "加载更多投稿") {
            Task { await load(reset: false) }
          }
        } else if !loading && error == nil {
          ContentUnavailableView("暂无投稿", systemImage: "play.rectangle")
        }
      }.padding(AppLayout.pageInset).padding(.vertical, 8)
    }.sheet(item: $spaceSheet) { target in
      VStack(spacing: 12) {
        HStack {
          Spacer()
          Button("完成") { spaceSheet = nil }.buttonStyle(.glass)
        }.padding(12)
        Group {
          switch target.kind {
          case .following: NativeRelationsPage(store: store, mid: target.mid, followers: false)
          case .followers: NativeRelationsPage(store: store, mid: target.mid, followers: true)
          case .dynamic: NativeDynamicsPage(store: store, mid: target.mid)
          case .collections: NativeCollectionsPage(store: store, mid: target.mid)
          case .account: NativeAccountPage(store: store)
          }
        }.padding(.horizontal, 16).padding(.bottom, 16)
      }.frame(minWidth: 900, minHeight: 680).background { GlassBackdrop() }
    }.onChange(of: store.navigationRevision) { spaceSheet = nil }
      .task(id: mid) { await load(reset: true) }
  }
  private func header(_ p: Profile) -> some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 20) {
        Thumbnail(url: p.face, mode: .fill, placeholder: "person.crop.circle.fill").frame(
          width: 84, height: 84
        ).clipShape(Circle())
        VStack(alignment: .leading, spacing: 8) {
          Text(p.name).font(AppLayout.pageTitle)
          Text("UID " + String(mid)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .textSelection(.enabled)
          if !p.bio.isEmpty {
            Text(p.bio).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
              .lineLimit(3)
          }
        }
        Spacer(minLength: 0)
        if ownProfile {
          Button("账户信息") { spaceSheet = SpaceSheet(mid: mid, kind: .account) }.buttonStyle(.glass)
        } else {
          Button(p.isFollowed ? "已关注" : "关注") { Task { await toggleFollow() } }.buttonStyle(.glass)
            .disabled(changingFollow)
          Button {
            store.inbox.select(
              Conversation(
                mid: mid, kind: 1, name: p.name, face: p.face, preview: "", unread: 0, timestamp: 0,
                system: false))
            store.navigate(.messages)
          } label: {
            Image(systemName: "envelope")
          }.buttonStyle(.glass).help("发私信")
        }
      }
      HStack(spacing: 30) {
        Button {
          spaceSheet = SpaceSheet(mid: mid, kind: .following)
        } label: {
          stat(p.following, label: "关注")
        }
        Button {
          spaceSheet = SpaceSheet(mid: mid, kind: .followers)
        } label: {
          stat(p.fans, label: "粉丝")
        }
        stat(p.videos, label: "投稿")
        Spacer()
      }.buttonStyle(.plain)
    }.padding(24).floatingGlass(26)
  }
  private func stat(_ value: Int, label: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text(value.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
      Text(label).font(.callout).foregroundStyle(.secondary)
    }
  }
  private var personalActions: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
      ForEach([Destination.favorites, .later, .history, .downloads, .messages], id: \.self) { d in
        Button {
          store.profileTarget = nil
          store.navigate(d)
        } label: {
          HStack(spacing: 10) {
            Image(systemName: d.icon).foregroundStyle(biliPink)
            Text(d.rawValue)
            Spacer(minLength: 0)
          }
          .padding(17).frame(maxWidth: .infinity).floatingGlass(18).contentShape(.rect(cornerRadius: 18))
        }.buttonStyle(.plain)
      }
    }
  }
  private func toggleFollow() async {
    guard store.account != nil else {
      store.login()
      return
    }
    guard let p = profile, !changingFollow else { return }
    changingFollow = true
    defer { changingFollow = false }
    do {
      _ = try await store.api.post(
        "/x/relation/modify", ["fid": "\(mid)", "act": p.isFollowed ? "2" : "1", "re_src": "11"])
      profile?.isFollowed.toggle()
    } catch { store.interactionMessage = error.localizedDescription }
  }
  private func load(reset: Bool) async {
    if reset {
      identity = UUID()
      loading = false
      profile = nil
    }
    guard !loading else { return }
    let token = identity
    loading = true
    error = nil
    defer { if token == identity { loading = false } }
    if reset {
      page = 1
      videos = []
      hasMore = true
      do {
        let value = try await store.api.profile(mid)
        guard token == identity else { return }
        profile = value
      } catch {
        if token == identity && !Task.isCancelled { self.error = error.localizedDescription }
      }
    }
    do {
      let next = reset ? 1 : page + 1
      let result = try await store.api.profileVideos(mid, page: next)
      try Task.checkCancellation()
      guard token == identity else { return }
      let ids = Set(videos.map(\.id))
      videos += Video.deduplicated(result, excluding: ids)
      page = next
      hasMore = !result.isEmpty && videos.count > ids.count
    } catch is CancellationError {} catch {
      if token == identity { self.error = error.localizedDescription }
    }
  }
}
struct DanmakuComposer: View {
  @Bindable var store: Store
  let aid: Int
  var body: some View {
    @Bindable var dm = store.danmaku
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Menu {
          Picker("位置", selection: $dm.mode) {
            Text("滚动").tag(1)
            Text("顶部").tag(5)
            Text("底部").tag(4)
          }
          Divider()
          Picker("字号", selection: $dm.fontSize) {
            Text("小").tag(18)
            Text("标准").tag(25)
          }
          Picker("颜色", selection: $dm.color) {
            Text("白色").tag(0xFFFFFF)
            Text("红色").tag(0xFF5555)
            Text("橙色").tag(0xFFAA33)
            Text("黄色").tag(0xFFFF00)
            Text("绿色").tag(0x00CC66)
            Text("蓝色").tag(0x66CCFF)
            Text("紫色").tag(0xCC66FF)
          }
        } label: { Text("弹幕样式") }
          .buttonStyle(.glass).fixedSize().help("设置发送弹幕的位置、字号和颜色")
        TextField(store.account == nil ? "登录后发送弹幕" : "发一条弹幕", text: $dm.message).textFieldStyle(
          .plain
        ).padding(10).appGlass(12).disabled(
          store.account == nil || dm.sending)
        Button(dm.sending ? "发送中" : "发送") {
          if store.account == nil {
            store.login()
          } else {
            Task { await dm.send(aid: aid, api: store.api, player: store.playback.player) }
          }
        }.buttonStyle(.glass).disabled(
          dm.sending || (store.account != nil && dm.message.isEmpty) || dm.message.count > 100)
      }
      if dm.items.contains(where: { $0.mode == 9 || $0.mode == 7 }) {
        Label("高级弹幕 · 原生播放", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
      }
      if dm.items.contains(where: { $0.mode == 8 }) {
        Text("部分旧版代码弹幕暂不支持").font(.caption).foregroundStyle(.secondary)
      }
      if dm.specialLoading {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(dm.specialProgress.isEmpty ? "加载高级弹幕" : dm.specialProgress).font(.caption)
        }.foregroundStyle(.secondary)
      }
      if dm.specialError != nil && !dm.specialLoading {
        Button("重试高级弹幕") { dm.retrySpecial(aid: aid, api: store.api) }.buttonStyle(.glass)
      }
      if let error = dm.sendError ?? dm.error ?? dm.specialError {
        Text(error).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
