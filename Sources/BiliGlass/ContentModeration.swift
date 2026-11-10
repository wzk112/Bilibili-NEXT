import SwiftUI

extension Store {
  func recommendationFeedback(_ video: Video, reason: Int) async {
    do {
      guard api.signedIn else { login(); return }
      let aid = try await api.videoAid(video)
      var owner = video.ownerID ?? 0
      if reason == 4 && owner <= 0 { owner = try await api.detail(video.bvid).ownerID }
      try await api.prepareVideoInteraction()
      _ = try await api.post("/x/web-interface/feedback/dislike", ["app_id": "100", "platform": "5", "from_spmid": "", "spmid": "333.1007.0.0", "goto": "av", "id": String(aid), "mid": String(owner), "track_id": video.recommendationTrackID ?? "", "feedback_page": "1", "reason_id": String(reason)])
      videos.removeAll { $0.bvid == video.bvid || (reason == 4 && video.ownerID != nil && $0.ownerID == video.ownerID) }
      extras.related.removeAll { $0.bvid == video.bvid || (reason == 4 && video.ownerID != nil && $0.ownerID == video.ownerID) }
      interactionMessage = "已提交推荐反馈"
    } catch { interactionMessage = error.localizedDescription }
  }
  func blockAuthor(_ video: Video) async {
    do {
      let mid: Int
      if let owner = video.ownerID { mid = owner } else { mid = try await api.detail(video.bvid).ownerID }
      guard mid > 0, mid != account?.mid else { throw BiliError(text: "无法屏蔽这个账号") }
      _ = try await api.post("/x/relation/modify", ["fid": String(mid), "act": "5", "re_src": "11"])
      blockedAuthors.insert(mid)
      videos.removeAll { $0.ownerID == mid }; extras.related.removeAll { $0.ownerID == mid }
      interactionMessage = "已拉黑该 UP 主"
    } catch { interactionMessage = error.localizedDescription }
  }
}
struct VideoContextActions: View {
  @Bindable var store: Store
  let video: Video
  var body: some View {
    Button("不感兴趣") { Task { await store.recommendationFeedback(video, reason: 1) } }
    Button("不想看此 UP 主") { Task { await store.recommendationFeedback(video, reason: 4) } }
    Divider()
    Button("举报视频…") { store.reportTarget = video }
    Button("拉黑 UP 主…") { store.blockTarget = video }
  }
}
struct VideoReportReason: Identifiable {
  let id: Int
  let title: String
  static func parse(_ value: Any?) -> [Self] {
    guard let rows = value as? [[String: Any]] else { return [] }
    var result: [Self] = []
    for row in rows {
      let children = ["sub_tag", "tags", "children", "list"].flatMap { parse(row[$0]) }
      if !children.isEmpty { result += children }
      else if row["sub_tag"] == nil, let id = row["tid"] as? Int, let title = row["name"] as? String, row["type"] as? String != "jump" { result.append(Self(id: id, title: title)) }
    }
    var seen: Set<Int> = []; return result.filter { seen.insert($0.id).inserted }
  }
}
struct VideoReportForm: View {
  @Bindable var store: Store
  let video: Video
  @Environment(\.dismiss) private var dismiss
  @State private var aid = 0
  @State private var reasons: [VideoReportReason] = []
  @State private var selected = 0
  @State private var description = ""
  @State private var source = ""
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("举报视频").font(.title2.bold()); Text(video.title).font(.callout).lineLimit(2)
      if reasons.isEmpty && error == nil { ProgressView("正在读取举报原因") }
      if !reasons.isEmpty { Picker("举报原因", selection: $selected) { ForEach(reasons) { Text($0.title).tag($0.id) } } }
      TextField("详细说明", text: $description, axis: .vertical).lineLimit(4...8).textFieldStyle(.roundedBorder)
      TextField("原创出处或证据链接（适用时填写）", text: $source).textFieldStyle(.roundedBorder)
      if let error { Text(error).foregroundStyle(.red).font(.callout) }
      HStack { Button("取消") { dismiss() }; Spacer(); Button(busy ? "正在提交" : "提交举报") { submit() }.disabled(busy || selected == 0 || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.buttonStyle(.appGlassButton)
    }.padding(24).frame(width: 540).background { GlassBackdrop() }.disabled(busy)
      .task {
        do { aid = try await store.api.videoAid(video); let data = try await store.api.request("/x/web-interface/appeal/v2/tags", ["aid": String(aid), "from": "app", "version": "v1"]); reasons = VideoReportReason.parse(data["tags"]); selected = reasons.first?.id ?? 0; if reasons.isEmpty { error = "未能读取可用的举报原因" } }
        catch { self.error = error.localizedDescription }
      }
  }
  private func submit() {
    busy = true; error = nil
    Task {
      do {
        _ = try await store.api.post("/x/web-interface/appeal/v2/submit", ["aid": String(aid), "tid": String(selected), "desc": description, "meta": source, "attach": "", "block_author": "false"])
        store.interactionMessage = "举报已提交"; dismiss()
      } catch { self.error = error.localizedDescription }
      busy = false
    }
  }
}
struct BlockedAuthor: Identifiable {
  let id: Int
  let name: String
}
@MainActor @Observable final class BlacklistModel {
  var rows: [BlockedAuthor] = []
  var error: String?
  var loading = false
  var hasMore = true
  private var page = 0
  private var identity = UUID()
  func load(api: API, reset: Bool = false) async {
    guard !loading, reset || hasMore else { return }
    if reset { identity = UUID() }
    let token = identity, auth = api.authenticationGeneration, next = reset ? 1 : page + 1
    loading = true; error = nil
    defer { if token == identity { loading = false } }
    do {
      let data = try await api.request("/x/relation/blacks", ["pn": String(next), "ps": "50"])
      guard token == identity, auth == api.authenticationGeneration, !Task.isCancelled else { return }
      let incoming = (data["list"] as? [[String: Any]] ?? []).compactMap { raw -> BlockedAuthor? in
        guard let id = raw["mid"] as? Int, id > 0 else { return nil }
        return BlockedAuthor(id: id, name: raw["uname"] as? String ?? "UID \(id)")
      }
      var ids = reset ? Set<Int>() : Set(rows.map(\.id))
      let unique = incoming.filter { ids.insert($0.id).inserted }
      if !reset && !incoming.isEmpty && unique.isEmpty && (data["total"] as? Int ?? Int.max) > rows.count {
        throw BiliError(text: "服务器返回了重复的黑名单分页，请重试")
      }
      rows = reset ? unique : rows + unique
      page = next
      let total = data["total"] as? Int
      hasMore = !incoming.isEmpty && !unique.isEmpty && (total.map { rows.count < $0 } ?? (incoming.count == 50))
    } catch { if token == identity && auth == api.authenticationGeneration && !Task.isCancelled { self.error = error.localizedDescription } }
  }
}
struct BlockedAuthorsPage: View {
  @Bindable var store: Store
  @Environment(\.dismiss) private var dismiss
  @State private var model = BlacklistModel()
  @State private var busy: Set<Int> = []
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack { Text("黑名单").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.buttonStyle(.appGlassButton).keyboardShortcut(.cancelAction) }
      ScrollView { LazyVStack(spacing: 12) {
        ForEach(model.rows) { row in
          HStack { Text(row.name); Spacer(); Button("解除拉黑") { unblock(row.id) }.buttonStyle(.appGlassButton).disabled(busy.contains(row.id)) }.padding(12).appGlass(12)
        }
        if model.rows.isEmpty && !model.loading && model.error == nil { ContentUnavailableView("黑名单为空", systemImage: "person.slash") }
        LoadMoreFooter(loading: model.loading, hasMore: model.hasMore, error: model.error, count: model.rows.count, title: "加载更多黑名单") { Task { await model.load(api: store.api) } }
      } }
    }.padding(24).frame(width: 520, height: 480).background { GlassBackdrop() }.task { await model.load(api: store.api) }
      .onChange(of: store.account?.mid) { dismiss() }
  }
  private func unblock(_ mid: Int) {
    busy.insert(mid)
    Task {
      do { _ = try await store.api.post("/x/relation/modify", ["fid": String(mid), "act": "6", "re_src": "11"]); store.blockedAuthors.remove(mid); await model.load(api: store.api, reset: true) }
      catch { model.error = error.localizedDescription }
      busy.remove(mid)
    }
  }
}
