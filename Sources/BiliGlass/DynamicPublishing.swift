import SwiftUI

enum DynamicPayload {
  static func request(text: String, emotes: [String: CommentEmote], images: [UploadedImage], uploadID: String, repostID: String?, aiGenerated: Bool) -> [String: Any] {
    let content = CommentTextContent(message: text, emotes: emotes)
    let nodes: [[String: Any]] = content.parts.compactMap { part in
      switch part {
      case .text(let value): return value.isEmpty ? nil : ["raw_text": value, "type": 1, "biz_id": ""]
      case .emote(let value): return ["raw_text": value.token, "type": 9, "biz_id": ""]
      }
    }
    let request: [String: Any] = [
      "content": ["contents": nodes], "scene": repostID == nil ? 2 : 4,
      "pics": images.map(\.commentPayload), "upload_id": uploadID,
      "meta": ["app_meta": ["from": "create.dynamic.web", "mobi_app": "web"]],
      "option": ["aigc": aiGenerated ? 1 : 2],
    ]
    var result: [String: Any] = ["dyn_req": request]
    if let repostID { result["web_repost_src"] = ["dyn_id_str": repostID] }
    return result
  }
}
extension API {
  /// Dynamic APIs use JSON and query CSRF. Keep them separate from form posts.
  func dynamicPost(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
    let allowed = ["/x/dynamic/feed/dyn/thumb", "/x/dynamic/feed/create/submit_check", "/x/dynamic/feed/create/dyn"]
    guard allowed.contains(path), signedIn, let csrf = cookies["bili_jct"] else { throw BiliError(text: "请先登录") }
    let auth = authenticationGeneration
    var components = URLComponents(string: "https://api.bilibili.com" + path)!
    components.queryItems = [URLQueryItem(name: "csrf", value: csrf), URLQueryItem(name: "platform", value: "web")]
    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
    Self.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("https://t.bilibili.com/", forHTTPHeaderField: "Referer")
    request.setValue("https://t.bilibili.com", forHTTPHeaderField: "Origin")
    request.setValue(cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
    let (data, response) = try await session.data(for: request)
    try Task.checkCancellation()
    guard auth == authenticationGeneration else { throw CancellationError() }
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BiliError(text: "动态请求失败") }
    guard root["code"] as? Int == 0 else { throw BiliError(text: root["message"] as? String ?? "动态操作失败", code: root["code"] as? Int) }
    let result = root["data"] as? [String: Any] ?? [:]
    if result["need_captcha"] as? Bool == true { throw BiliError(text: "请先在官方动态页完成验证", code: -352) }
    return result
  }
  func publishDynamic(_ body: [String: Any]) async throws -> String {
    guard let request = body["dyn_req"] as? [String: Any] else { throw BiliError(text: "动态内容无效") }
    let auth = authenticationGeneration
    _ = try await dynamicPost("/x/dynamic/feed/create/submit_check", [
      "content": request["content"] ?? [:], "pics": request["pics"] ?? [],
      "scene": request["scene"] ?? 2, "create_option": request["option"] ?? [:],
    ])
    guard auth == authenticationGeneration else { throw CancellationError() }
    let result = try await dynamicPost("/x/dynamic/feed/create/dyn", body)
    guard let id = result["dyn_id_str"] as? String ?? result["dyn_id"].flatMap({ ($0 as? NSNumber)?.stringValue }), !id.isEmpty else {
      throw BiliError(text: "服务器已接收，请刷新动态确认发布结果后再操作")
    }
    return id
  }
}

@MainActor @Observable final class DynamicDraft {
  var text = ""
  var images: [URL] = []
  var emotes: [String: CommentEmote] = [:]
  var aiGenerated = false
  var publishing = false
  var error: String?
  private var uploadID = ""
  private var uploaded: [URL: UploadedImage] = [:]
  func clear() { text = ""; images = []; emotes = [:]; error = nil; uploadID = ""; uploaded = [:]; aiGenerated = false }
  func publish(api: API, mid: Int, repostID: String?) async -> Bool {
    guard !publishing, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || repostID != nil else { return false }
    guard text.count <= 2000 else { error = "动态正文最多 2000 字"; return false }
    let auth = api.authenticationGeneration
    publishing = true; error = nil; defer { publishing = false }
    do {
      if uploadID.isEmpty { uploadID = "\(mid)_\(Int(Date().timeIntervalSince1970))_\(Int.random(in: 1000...9999))" }
      for image in images where uploaded[image] == nil {
        uploaded[image] = try await api.uploadImage(image, business: "new_dyn")
        guard auth == api.authenticationGeneration else { throw CancellationError() }
      }
      let body = DynamicPayload.request(text: text, emotes: emotes, images: images.compactMap { uploaded[$0] }, uploadID: uploadID, repostID: repostID, aiGenerated: aiGenerated)
      _ = try await api.publishDynamic(body)
      clear(); return true
    } catch {
      if auth == api.authenticationGeneration { self.error = error.localizedDescription + "。若网络中断，请先刷新动态确认是否已发布。" }
      return false
    }
  }
}
#if os(macOS)
struct DynamicComposer: View {
  @Bindable var store: Store
  @Bindable var draft: DynamicDraft
  var repost: DynamicEntry? = nil
  var published: () -> Void
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(repost == nil ? "发布动态" : "转发动态").font(.title2.bold())
      if let repost { Text("@\(repost.author)  \(repost.text)").font(.callout).lineLimit(3).padding(12).appGlass(12) }
      TextEditor(text: $draft.text).font(.body).scrollContentBackground(.hidden).padding(10).appGlass(14).frame(height: 180)
        .accessibilityLabel("动态正文")
      HStack {
        EmojiPicker(api: store.api) { draft.emotes[$0.token] = $0; draft.text += $0.token }
        if repost == nil {
          Button { for url in ImageAttachment.choose(multiple: true) where !draft.images.contains(url) && draft.images.count < 9 { draft.images.append(url) } } label: { Label("添加图片", systemImage: "photo.badge.plus") }.buttonStyle(.appGlassButton)
        }
        Spacer(); Text("\(draft.text.count) / 2000").font(.caption).foregroundStyle(draft.text.count > 2000 ? .red : .secondary)
      }
      if !draft.images.isEmpty { AttachedImages(urls: $draft.images) }
      Toggle("包含 AI 生成内容", isOn: $draft.aiGenerated)
      if let error = draft.error {
        Text(error).font(.callout).foregroundStyle(.red)
        Link("打开官方动态页完成验证或确认结果", destination: URL(string: "https://t.bilibili.com/")!)
      }
      HStack {
        Button("取消") { dismiss() }
        Spacer()
        Button(draft.publishing ? "正在发布…" : repost == nil ? "发布" : "转发") {
          guard let account = store.account else { return }
          Task { if await draft.publish(api: store.api, mid: account.mid, repostID: repost?.id) { published(); dismiss() } }
        }.disabled(store.account == nil || draft.text.count > 2000 || (draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.images.isEmpty && repost == nil))
      }.buttonStyle(.appGlassButton)
    }.padding(24).frame(width: 620).background { GlassBackdrop() }.disabled(draft.publishing).interactiveDismissDisabled(draft.publishing)
  }
}
struct DynamicActions: View {
  @Bindable var store: Store
  let entry: DynamicEntry
  var comment: (() -> Void)? = nil
  @State private var liked = false
  @State private var count = 0
  @State private var busy = false
  @State private var error: String?
  @State private var reposting = false
  @State private var draft = DynamicDraft()
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 14) {
        Button { toggleLike() } label: { Label(count > 0 ? String(count) : "点赞", systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup") }.tint(liked ? biliPink : nil).disabled(busy || store.account == nil)
        Button { reposting = true } label: { Label(entry.repostCount > 0 ? String(entry.repostCount) : "转发", systemImage: "arrowshape.turn.up.right") }.disabled(store.account == nil)
        if let comment { Button(action: comment) { Label(entry.commentCount > 0 ? String(entry.commentCount) : "评论", systemImage: "bubble") } }
        Spacer()
      }.buttonStyle(.appGlassButton)
      if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
    }.onAppear { liked = entry.liked; count = entry.likeCount }
      .sheet(isPresented: $reposting) { DynamicComposer(store: store, draft: draft, repost: entry) { store.interactionMessage = "动态已转发" } }
  }
  private func toggleLike() {
    guard !busy else { return }; busy = true; error = nil
    let next = !liked
    Task {
      do { _ = try await store.api.dynamicPost("/x/dynamic/feed/dyn/thumb", ["dyn_id_str": entry.id, "up": next ? 1 : 2]); liked = next; count = max(0, count + (next ? 1 : -1)) }
      catch { self.error = error.localizedDescription }
      busy = false
    }
  }
}

#endif
