import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

@MainActor func importPhoto(_ item: PhotosPickerItem) async throws -> URL {
  guard let data = try await item.loadTransferable(type: Data.self), data.count <= 20 * 1024 * 1024
  else { throw BiliError(text: "图片无法读取或体积过大") }
  let type = item.supportedContentTypes.first ?? .jpeg
  let accepted: [UTType] = [.jpeg, .png, .webP, .gif]
  let content: Data
  let ext: String
  if accepted.contains(where: { type.conforms(to: $0) }) {
    content = data
    ext = type.preferredFilenameExtension ?? "jpg"
  } else {
    guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else {
      throw BiliError(text: "图片格式无法转换")
    }
    content = jpeg
    ext = "jpg"
  }
  guard content.count <= 10 * 1024 * 1024 else { throw BiliError(text: "图片需小于 10 MB") }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Attachments")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
  try content.write(to: url, options: .atomic)
  return url
}
struct MobileComments: View {
  @Bindable var store: Store
  let aid: Int
  @Bindable var model: Comments
  var type = 1
  @Environment(\.dynamicTypeSize) private var textSize
  var body: some View {
    LazyVStack(alignment: .leading, spacing: 18) {
      HStack {
        Text(model.hasLoadedCount ? "评论 \(model.count ?? 0)" : "评论").font(.headline)
        Spacer()
        Picker("排序", selection: $model.sort) {
          Text("最热").tag(1)
          Text("最新").tag(0)
        }.pickerStyle(.segmented).frame(width: 150)
      }.onChange(of: model.sort) { model.load(aid: aid, type: type, api: store.api) }
      MobileCommentComposer(store: store, aid: aid, model: model)
      ForEach(model.items) { reply in
        MobileReply(store: store, reply: reply, model: model, aid: aid)
        ForEach(model.expanded[reply.id] ?? reply.children) { child in
          MobileReply(store: store, reply: child, model: model, aid: aid).padding(.leading, 22)
        }
        if reply.count > (model.expanded[reply.id] ?? reply.children).count
          && model.childHasMore[reply.id] != false
        {
          Button(model.childLoading.contains(reply.id) ? "加载中" : "共 \(reply.count) 条回复 · 展开更多") {
            Task { await model.children(reply, aid: aid, api: store.api) }
          }.disabled(model.childLoading.contains(reply.id))
        }
        if let error = model.childErrors[reply.id] {
          Text(error).font(.caption).foregroundStyle(.secondary)
        }
        Divider()
      }
      if model.loading { ProgressView().frame(maxWidth: .infinity) }
      if let error = model.error {
        MobileError(text: error) {
          model.load(aid: aid, type: type, api: store.api, more: !model.items.isEmpty)
        }
      }
      if model.hasMore && !model.loading {
        Button("加载更多评论") {
          model.load(aid: aid, type: type, api: store.api, more: !model.items.isEmpty)
        }.buttonStyle(.appGlassButton).frame(maxWidth: .infinity)
      }
      if !model.loading && model.items.isEmpty && model.error == nil {
        Text("还没有评论").foregroundStyle(.secondary)
      }
    }.task(id: "\(type):\(aid)") { model.loadIfNeeded(aid: aid, type: type, api: store.api) }

      .sheet(isPresented: Binding(get: { model.replyingTo != nil }, set: { if !$0 { model.replyingTo = nil } })) {
        MobileReplyComposerSheet(store: store, aid: aid, model: model)
      }
  }
}

struct MobileCommentComposer: View {
  @Bindable var store: Store
  let aid: Int
  @Bindable var model: Comments
  @Environment(\.dynamicTypeSize) private var textSize
  @State private var photos: [PhotosPickerItem] = []
  @State private var photoBusy = false
  @State private var photoError: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let reply = model.replyingTo {
        HStack {
          Text("回复 @" + reply.name).font(.caption)
          Spacer()
          Button("取消") { model.replyingTo = nil }
        }
      }
      TextField(store.account == nil ? "登录后评论" : "发表评论", text: $model.draft, axis: .vertical)
        .lineLimit(2...6).textFieldStyle(.plain).padding(12)
        .appGlassEffect(.regular, in: .rect(cornerRadius: 18)).disabled(model.sending)
        .accessibilityIdentifier("comment-draft")
      let composeLayout =
        textSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
      composeLayout {
        EmojiPicker(api: store.api) { model.draft += $0.token }
        PhotosPicker(
          selection: $photos, maxSelectionCount: max(1, 9 - model.attachments.count),
          matching: .images
        ) { MobileComposerIcon(name: "photo") }.buttonStyle(.plain).accessibilityLabel("选择评论图片")
          .disabled(
            photoBusy || model.attachments.count >= 9 || model.sending)
        if photoBusy { ProgressView() }
        Text("\(model.attachments.count)/9").font(.caption).foregroundStyle(.secondary)
        if !textSize.isAccessibilitySize { Spacer() }
        Button(model.sending ? "发送中" : "发送") {
          if store.account == nil {
            store.login()
          } else {
            Task { await model.send(aid: aid, api: store.api) }
          }
        }.buttonStyle(.appGlassProminent).disabled(
          model.sending || photoBusy || model.draft.count > 1000
            || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && model.attachments.isEmpty)
        )
      }
      if !model.attachments.isEmpty {
        ScrollView(.horizontal) {
          HStack {
            ForEach(model.attachments, id: \.self) { url in
              HStack {
                Image(systemName: "photo")
                Text(url.lastPathComponent.prefix(8))
                Button {
                  model.attachments.removeAll { $0 == url }
                } label: {
                  Image(systemName: "xmark.circle")
                }
              }.font(.caption).padding(8).background(.quaternary, in: .capsule)
            }
          }
        }
      }
      if let error = photoError ?? model.sendError {
        Text(error).font(.caption).foregroundStyle(.red)
        Button("官方验证") { store.verify("评论验证") }
      }
      if let submitted = model.submittedText {
        VStack(alignment: .leading, spacing: 6) {
          Text(model.submissionStatus ?? "服务器已接收").font(.subheadline.bold())
          Text(submitted).font(.callout)
          Text("公开显示以服务端为准。").font(.caption).foregroundStyle(.secondary)
        }.appGlass()
      }
    }
      .onChange(of: photos) { _, items in
        Task {
          photoBusy = true
          photoError = nil
          defer {
            photoBusy = false
            photos = []
          }
          do {
            for item in items where model.attachments.count < 9 {
              model.attachments.append(try await importPhoto(item))
            }
          } catch { photoError = error.localizedDescription }
        }
      }
  }
}
struct MobileReplyComposerSheet: View {
  @Bindable var store: Store
  let aid: Int
  @Bindable var model: Comments
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      ScrollView { MobileCommentComposer(store: store, aid: aid, model: model).padding() }
        .navigationTitle("回复评论").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("收起") { dismiss() } } }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
      .onChange(of: model.replyingTo?.id) { if model.replyingTo == nil { dismiss() } }
  }
}

struct MobileReply: View {
  @Bindable var store: Store
  let reply: Reply
  @Bindable var model: Comments
  let aid: Int
  @State private var gallery: GalleryTarget?
  @State private var deleting = false
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      MobileProfileLink(store: store, mid: reply.mid) {
        MobileAvatar(url: reply.face).frame(width: 34, height: 34).clipShape(.circle)
      }.buttonStyle(.plain)
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          MobileProfileLink(store: store, mid: reply.mid) {
            Text(reply.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(
              1)
          }.buttonStyle(.plain)
          if reply.mid == store.playback.detail?.ownerID {
            Text("UP主").font(.caption2.weight(.semibold)).foregroundStyle(biliPink)
          }
          Spacer(minLength: 8)
          Button {
            if store.account == nil {
              store.login()
            } else {
              Task { await model.like(reply, aid: aid, api: store.api) }
            }
          } label: {
            Label(
              String(reply.likes), systemImage: reply.liked ? "hand.thumbsup.fill" : "hand.thumbsup"
            )
            .font(.caption).monospacedDigit()
          }.buttonStyle(.plain).foregroundStyle(reply.liked ? biliPink : .secondary)
        }.frame(minHeight: 34)
        CommentText(content: reply.textContent).frame(maxWidth: .infinity, alignment: .leading)
        ForEach(reply.videoLinks, id: \.url) { link in CommentVideoCard(link: link, store: store) }
        if !reply.pictures.isEmpty {
          ScrollView(.horizontal) {
            HStack(spacing: 8) {
              ForEach(reply.pictures, id: \.self) { picture in
                Button {
                  gallery = GalleryTarget(url: picture)
                } label: {
                  Thumbnail(url: picture).frame(width: 108, height: 108).clipShape(
                    .rect(cornerRadius: 10))
                }.buttonStyle(.plain)
              }
            }
          }
        }
        HStack(alignment: .bottom, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(reply.date.formatted(AppDateFormat.timestamp))
            if !reply.location.isEmpty { Text(reply.location) }
          }.font(.caption2).foregroundStyle(.secondary)
          Spacer(minLength: 4)
          Button("回复") { model.replyingTo = reply }.font(.caption).buttonStyle(.plain)
            .foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 32)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.contextMenu {
      Button("复制") { UIPasteboard.general.string = reply.message }
      Button("回复") { model.replyingTo = reply }
      if reply.mid == store.account?.mid { Button("删除", role: .destructive) { deleting = true } }
    }
    .sheet(item: $gallery) { MobileGallery(target: $0) }
    .confirmationDialog("删除自己的评论？", isPresented: $deleting, titleVisibility: .visible) {
      Button("删除", role: .destructive) {
        Task {
          do {
            _ = try await store.api.post(
              "/x/v2/reply/del",
              ["type": String(model.resourceType), "oid": String(aid), "rpid": String(reply.id)])
            model.load(aid: aid, type: model.resourceType, api: store.api)
          } catch { model.sendError = error.localizedDescription }
        }
      }
    }
  }
}
struct GalleryTarget: Identifiable {
  let id = UUID()
  let url: String
}
struct MobileGallery: View {
  let target: GalleryTarget
  @State private var image: UIImage?
  @State private var file: URL?
  @State private var error: String?
  @State private var retry = 0
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      ZStack {
        Color.black.ignoresSafeArea()
        if let image {
          MobileZoomableImage(image: image)
        } else if let error {
          VStack(spacing: 16) {
            Text(error).foregroundStyle(.white).padding()
            Button("重试") { retry += 1 }.buttonStyle(.appGlassButton)
          }
        } else {
          ProgressView().tint(.white)
        }
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
        ToolbarItem(placement: .topBarTrailing) {
          if let file { ShareLink(item: file) { Image(systemName: "square.and.arrow.up") } }
        }
      }
      .task(id: "\(target.url):\(retry)") {
        error = nil
        #if DEBUG
          if MobileUIFixture.enabled && target.url == "fixture:gallery" {
            image = MobileUIFixture.image
            return
          }
        #endif
        do {
          guard let url = BiliImageURL.parse(target.url) else { throw BiliError(text: "图片地址无效") }
          var request = URLRequest(url: url)
          request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
          let (data, response) = try await URLSession.shared.data(for: request)
          try Task.checkCancellation()
          guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 30 * 1024 * 1024,
            let decoded = UIImage(data: data)
          else { throw BiliError(text: "图片读取失败") }
          image = decoded
          let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
          let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
          ).appendingPathExtension(ext)
          try data.write(to: destination, options: .atomic)
          file = destination
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
      }
    }.onDisappear { if let file { try? FileManager.default.removeItem(at: file) } }
  }
}
struct MobileInteractionSheet: View {
  @Bindable var store: Store
  let detail: Detail
  let kind: String
  let relogin: () -> Void
  @State private var amount = 1
  @State private var alsoLike = false
  @State private var balance: Double?
  @State private var editor: FavoriteEditor?
  @State private var title = ""
  @State private var privateFolder = false
  @State private var localError: String?
  @State private var discardChanges = false
  @State private var preparing = true
  @Environment(\.dismiss) private var dismiss
  private var limit: Int { detail.copyright == 2 ? 1 : 2 }
  private var choice: CoinAvailability { CoinAvailability(limit: limit, coins: store.actions.relation?.coins, balance: balance) }
  private var busy: Bool { preparing || store.actions.loading || store.actions.operation != nil }
  var body: some View {
    NavigationStack {
      Form {
        Section { Text(detail.video.title).font(.headline) }
        if kind == "favorite" {
          if let editor { favoriteContents(editor) } else { Section { ProgressView("正在加载收藏夹") } }
        } else if kind == "coin" {
          Section("投币") {
            LabeledContent("我的硬币", value: balance?.formatted(.number.precision(.fractionLength(0...1))) ?? "—")
            LabeledContent("本视频已投", value: store.actions.relation.map { "\($0.coins) / \(limit) 枚" } ?? "—")
              .accessibilityIdentifier("coin-relation")
            HStack(spacing: 12) {
              ForEach(1...2, id: \.self) { value in
                Button { amount = value } label: {
                  VStack(spacing: 8) { Image(systemName: "c.circle").font(.title2); Text("\(value) 枚").font(.headline) }
                    .frame(maxWidth: .infinity).padding(.vertical, 12).contentShape(.rect(cornerRadius: 16))
                }.buttonStyle(.plain).foregroundStyle(.primary)
                  .appGlassEffect(.regular.tint(amount == value ? biliPink.opacity(0.22) : .clear), in: .rect(cornerRadius: 16))
                  .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(amount == value ? biliPink : .clear, lineWidth: 1.5).allowsHitTesting(false) }
                  .opacity(value > choice.available ? 0.4 : 1)
                  .disabled(busy || value > choice.available)
                  .accessibilityIdentifier("coin-amount-\(value)")
                  .accessibilityAddTraits(amount == value ? .isSelected : [])
                  .accessibilityHint(choice.reason(for: value) ?? "")
              }
            }
            if store.actions.relation?.liked != true { Toggle("同时点赞", isOn: $alsoLike).disabled(busy) }
            if preparing { ProgressView("正在读取投币状态") }
            else if let reason = choice.reason(for: 2) { Text(reason).font(.caption).foregroundStyle(.secondary) }
            Button(store.actions.operation == "coin" ? "提交中…" : "投 \(amount) 枚") {
              Task {
                if await store.actions.sendCoins(
                  amount: amount, limit: detail.copyright == 2 ? 1 : 2, balance: balance ?? 0,
                  alsoLike: alsoLike, api: store.api)
                {
                  dismiss()
                }
              }
            }.disabled(busy || choice.reason(for: amount) != nil)
              .accessibilityIdentifier("submit-coins")
          }
          Text("投币后无法撤回。结果未确认时先刷新，不自动重试。").font(.caption).foregroundStyle(.secondary)
        } else if kind == "triple" {
          Section {
            Label("点赞", systemImage: "hand.thumbsup")
            Label("投币", systemImage: "c.circle")
            Label("收藏到默认收藏夹", systemImage: "star")
            Button("确认三连") {
              Task { if await store.actions.sendTriple(api: store.api) { dismiss() } }
            }.disabled(busy || store.actions.relation == nil)
          }
          Text("投币后无法撤回；分别保留服务器确认的结果。").font(.caption).foregroundStyle(.secondary)
        } else if kind == "download" {
          Section {
            Text("已创建应用缓存任务，请到资料库的下载页查看。")
            Text("此预览版下载在前台运行；挂起后可能暂停，回到应用后可继续。").font(.caption).foregroundStyle(.secondary)
          }
        }
        if let error = localError ?? store.actions.error {
          Section {
            Text(error).foregroundStyle(.red)
            Button("刷新状态") { Task { await prepare() } }.disabled(busy)
            Button("重新登录", action: relogin).disabled(busy).accessibilityIdentifier("interaction-relogin")
            Link("在网页打开", destination: VideoShareLink.make(bvid: detail.video.bvid, page: 1, seconds: nil))
              .disabled(busy)
          }
        }
        if let notice = store.actions.notice {
          Section {
            Text(notice)
            if store.actions.relation == nil { Button("刷新状态") { Task { await prepare() } }.disabled(busy) }
          }
        }
      }.navigationTitle(
        kind == "coin" ? "投币" : kind == "triple" ? "一键三连" : kind == "download" ? "下载" : "收藏"
      ).navigationBarTitleDisplayMode(.inline).toolbar {
        if kind == "favorite" {
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") {
              if editor?.changes.isEmpty == false { discardChanges = true } else { dismiss() }
            }.disabled(editor?.saving == true)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button {
              Task { await saveFavorites() }
            } label: {
              if editor?.saving == true { ProgressView() } else { Text("完成") }
            }.disabled(editor?.loaded != true || editor?.loading == true || editor?.saving == true)
              .accessibilityIdentifier("save-favorites")
          }
        } else {
          ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(store.actions.operation != nil) }
        }
      }.task {
        await prepare()
      }
      .interactiveDismissDisabled(
        store.actions.operation != nil || editor?.saving == true || editor?.changes.isEmpty == false
      )
      .confirmationDialog("放弃收藏更改？", isPresented: $discardChanges, titleVisibility: .visible) {
        Button("放弃更改", role: .destructive) { dismiss() }
        Button("继续编辑", role: .cancel) {}
      }
    }.presentationDetents(kind == "download" ? [.medium, .large] : [.large])
  }
  @ViewBuilder private func favoriteContents(_ editor: FavoriteEditor) -> some View {
    @Bindable var editor = editor
    Section("收藏夹") {
      if editor.loading { ProgressView() }
      ForEach(editor.folders) { folder in
        Toggle(
          isOn: Binding(
            get: { editor.selected.contains(folder.id) },
            set: { selected in
              if selected {
                editor.selected.insert(folder.id)
              } else {
                editor.selected.remove(folder.id)
              }
            })
        ) {
          HStack(spacing: 12) {
            Image(systemName: folder.isPrivate ? "lock" : "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
              Text(folder.title).foregroundStyle(.primary)
              Text(folder.isPrivate ? "私密" : "公开").font(.caption).foregroundStyle(.secondary)
            }
          }.frame(minHeight: 32).contentShape(Rectangle())
        }.toggleStyle(.switch).disabled(editor.saving || editor.loading || !editor.loaded)
          .accessibilityIdentifier("favorite-folder-\(folder.id)")
          .accessibilityHint("开关表示是否将此视频加入收藏夹")
      }
      if let error = editor.error { Text(error).foregroundStyle(.red) }
      if editor.error != nil {
        Button("重新加载收藏状态") { Task { await editor.load(api: store.api) } }
      }
      if editor.loaded && editor.folders.isEmpty {
        Text("还没有收藏夹，可以在下方创建。 ").foregroundStyle(.secondary)
      }
      Button(editor.saving ? "正在保存…" : "保存变更") {
        Task { await saveFavorites() }
      }.disabled(!editor.loaded || editor.loading || editor.saving || editor.changes.isEmpty)
    }
    Section("新建收藏夹") {
      TextField("名称", text: $title)
      Toggle("私密", isOn: $privateFolder)
      Button("创建收藏夹") {
        Task {
          if await editor.create(title: title, isPrivate: privateFolder, api: store.api) {
            title = ""
          }
        }
      }.disabled(
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !editor.loaded
          || editor.loading || editor.saving)
      Text("创建会立即提交，视频收藏变更在保存时应用。").font(.caption).foregroundStyle(.secondary)
    }
  }
  private func saveFavorites() async {
    guard let editor, editor.loaded, !editor.loading, !editor.saving else { return }
    let before = !editor.original.isEmpty
    let changed = !editor.changes.isEmpty
    if await editor.save(api: store.api) {
      store.actions.favoritesSaved(
        aid: detail.aid, isFavorite: !editor.selected.isEmpty,
        wasFavorite: before)
      if changed { store.favoriteRevision += 1 }
      dismiss()
    }
  }
  private func prepare() async {
    preparing = true; localError = nil; balance = nil
    defer { preparing = false }
    let session = store.api.authenticationGeneration
    if kind == "favorite" {
      guard let account = store.account else {
        localError = "请先登录后再收藏"
        return
      }
      let model = editor ?? FavoriteEditor(aid: detail.aid, mid: account.mid)
      editor = model
      // Folder membership is sufficient to edit favorites; relation lookup must not block it.
      await model.load(api: store.api)
      store.writeFavoritesQA(model)
      return
    }
    await store.actions.load(detail: detail, accountID: store.account?.mid, api: store.api)
    if kind == "coin" {
      do {
        let data = try await store.api.request("/x/web-interface/nav")
        guard !Task.isCancelled, session == store.api.authenticationGeneration else { return }
        guard let money = data["money"] as? Double, money.isFinite else { throw BiliError(text: "未能读取硬币余额，请刷新") }
        balance = max(0, money)
        amount = min(max(1, choice.available), amount)
      } catch { if !Task.isCancelled, session == store.api.authenticationGeneration { localError = error.localizedDescription } }
    }
  }
}
struct MobileDownloadsPage: View {
  @Bindable var store: Store
  @State private var deleting: [SavedDownload] = []
  @State private var removing: [SavedDownload] = []
  @State private var selecting = false
  @State private var selected = Set<UUID>()
  private var selectedEntries: [SavedDownload] { store.downloads.saved.filter { selected.contains($0.id) } }
  var body: some View {
    List {
      Section {
        Text("下载在前台运行，挂起后可能暂停。任务与已收分块会保留，重新打开后可继续。")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let message = store.downloads.message { Section { Text(message) } }
      if selecting {
        Section {
          Button(selected.count == store.downloads.saved.count ? "取消全选" : "全选已完成") {
            selected = selected.count == store.downloads.saved.count ? [] : Set(store.downloads.saved.map(\.id))
          }.accessibilityIdentifier("downloads-select-all")
          Button("移除记录（\(selectedEntries.count)）") { removing = selectedEntries }
            .disabled(selectedEntries.isEmpty)
          Button("删除缓存（\(selectedEntries.filter { $0.cached == true }.count)）", role: .destructive) {
            deleting = selectedEntries.filter { $0.cached == true }
          }.disabled(!selectedEntries.contains { $0.cached == true })
            .accessibilityIdentifier("downloads-delete-selected")
        } footer: {
          Text("仅选择已完成的下载。移除记录会保留文件；删除缓存会同时删除视频和弹幕文件。")
        }
      }
      if store.downloads.jobs.contains(where: { !$0.finished }) {
        Section("进行中") {
          ForEach(store.downloads.jobs.filter { !$0.finished }, id: \.pendingRowID) { job in
            VStack(alignment: .leading, spacing: 10) {
              Text(job.video.title).lineLimit(2)
              ProgressView(value: job.progress)
              HStack {
                Text(job.error ?? job.status).font(.caption)
                Spacer()
                if job.cancelled || job.error != nil {
                  Button("继续") { store.downloads.retry(job, api: store.api) }
                } else {
                  Button("暂停") { store.downloads.pause(job) }
                }
                Menu { Button("移除任务", role: .destructive) { store.downloads.removeJob(job) } }
                  label: { Image(systemName: "ellipsis") }
              }
            }
          }
        }
      }
      if !store.downloads.saved.isEmpty {
        Section("已完成") {
          ForEach(store.downloads.saved, id: \.completedRowID) { entry in
            HStack(alignment: .top, spacing: 12) {
              if selecting {
                Button {
                  if !selected.insert(entry.id).inserted { selected.remove(entry.id) }
                } label: {
                  Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                    .frame(width: 44, height: 44)
                }.accessibilityLabel("选择 " + entry.video.title)
                  .accessibilityValue(selected.contains(entry.id) ? "已选择" : "未选择")
              }
              VStack(alignment: .leading, spacing: 10) {
                Text(entry.video.title).lineLimit(2)
                Text(entry.quality + (entry.danmakuPath == nil ? "" : " · 含弹幕"))
                  .font(.caption).foregroundStyle(.secondary)
                if !selecting {
                  HStack {
                    Button("离线播放") { store.openSaved(entry) }
                    Spacer()
                    ShareLink(item: URL(fileURLWithPath: entry.path)) { Image(systemName: "square.and.arrow.up") }
                    Menu {
                      Button("移除记录") { store.downloads.forget(entry) }
                      if entry.cached == true { Button("删除文件", role: .destructive) { deleting = [entry] } }
                    } label: { Image(systemName: "ellipsis") }
                  }
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
      if !store.downloads.jobs.contains(where: { !$0.finished }) && store.downloads.saved.isEmpty {
        ContentUnavailableView("还没有下载", systemImage: "arrow.down.circle", description: Text("播放页选择清晰度后点击下载"))
      }
    }.buttonStyle(.borderless).navigationTitle("下载")
      .toolbar {
        Button(selecting ? "完成" : "选择") { selecting.toggle(); selected.removeAll() }
          .disabled(store.downloads.saved.isEmpty && !selecting)
          .accessibilityIdentifier("downloads-selection")
      }
      .onChange(of: store.downloads.saved.map(\.id)) {
        selected.formIntersection(store.downloads.saved.map(\.id))
      }
      .confirmationDialog("删除 \(deleting.count) 个缓存文件？", isPresented: Binding(
        get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }), titleVisibility: .visible
      ) {
        Button("删除缓存文件", role: .destructive) {
          let entries = deleting
          deleting = []
          process(entries, deleteFiles: true)
        }
        Button("取消", role: .cancel) { deleting = [] }
      } message: { Text("将从此设备删除选中的视频和弹幕文件，此操作不可撤销。") }
      .confirmationDialog("移除 \(removing.count) 条下载记录？", isPresented: Binding(
        get: { !removing.isEmpty }, set: { if !$0 { removing = [] } }), titleVisibility: .visible
      ) {
        Button("移除记录", role: .destructive) {
          let entries = removing
          removing = []
          process(entries, deleteFiles: false)
        }
        Button("取消", role: .cancel) { removing = [] }
      } message: { Text("文件仍保留在此设备上，不会删除视频或弹幕文件。") }
  }
  private func process(_ entries: [SavedDownload], deleteFiles: Bool) {
    var completed = 0
    var errors: [String] = []
    for entry in entries {
      let success = deleteFiles ? store.downloads.deleteCache(entry) : store.downloads.forget(entry)
      if success {
        completed += 1
        selected.remove(entry.id)
      } else {
        selected.insert(entry.id)
        if let error = store.downloads.message, !errors.contains(error) { errors.append(error) }
      }
    }
    let failed = entries.count - completed
    if failed == 0 {
      store.downloads.message = deleteFiles ? "已删除 \(completed) 个缓存。" : "已移除 \(completed) 条下载记录。"
    } else {
      store.downloads.message = "\(completed) 项处理完成，\(failed) 项未完成，请重试。"
        + (errors.isEmpty ? "" : "\n" + errors.joined(separator: "\n"))
    }
  }
}

struct MobileNoticeComment: View {
  @Bindable var store: Store
  let notice: NativeNotice
  @State private var model = Comments()
  @State private var retry = 0
  @State private var originalPage: WebTarget?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      ScrollViewReader { reader in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if model.loading { ProgressView("正在定位评论") }
          if let target = notice.commentTarget {
            ForEach(model.items) { reply in
              Text("消息中的评论").font(.caption).foregroundStyle(.secondary)
              MobileReply(store: store, reply: reply, model: model, aid: target.oid)
                .accessibilityIdentifier("focused-comment")
            }
            if !model.focusedReplies.isEmpty {
              Divider()
              Text("同一条评论下的回复").font(.subheadline.weight(.medium))
              ForEach(model.focusedReplies) { reply in
                MobileReply(store: store, reply: reply, model: model, aid: target.oid)
                Divider()
              }
            }
            if let root = model.focusedRoot {
              if let error = model.childErrors[root.id] { Text(error).font(.caption).foregroundStyle(.secondary) }
              if model.childHasMore[root.id] != false {
                Button(model.childLoading.contains(root.id) ? "加载中" : "加载更多回复") {
                  Task { await model.children(root, aid: target.oid, api: store.api, pageSize: 49) }
                }.disabled(model.childLoading.contains(root.id))
              }
            }
          }
          if let submitted = model.submittedText {
            VStack(alignment: .leading, spacing: 6) {
              Text(model.submissionStatus ?? "服务器已接收").font(.subheadline.weight(.medium))
              Text(submitted).font(.callout)
              Text("公开显示以服务端为准。").font(.caption).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
              .background(.quaternary, in: .rect(cornerRadius: 12)).id("submission")
              .accessibilityIdentifier("notice-reply-receipt")
          }
          if let error = model.error { MobileError(text: error) { retry += 1 } }
          if let url = notice.originalPageURL {
            Button("查看原页面") { originalPage = WebTarget(url: url, title: "原页面") }
          }
        }.padding()
      }.onChange(of: model.sending) { if !model.sending, model.submittedText != nil { reader.scrollTo("submission", anchor: .bottom) } }
      }.navigationTitle("评论回复").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
      .task(id: retry) {
        if let target = notice.commentTarget { _ = await model.loadFocused(target, api: store.api) }
      }
      .sheet(isPresented: Binding(get: { model.replyingTo != nil }, set: { if !$0 { model.replyingTo = nil } })) {
        if let target = notice.commentTarget { MobileReplyComposerSheet(store: store, aid: target.oid, model: model) }
      }
      .sheet(item: $originalPage) { MobileWebPage(store: store, target: $0) }
  }
}
