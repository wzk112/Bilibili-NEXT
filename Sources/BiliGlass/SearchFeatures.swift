import SwiftUI

struct SearchOptions: Equatable {
  var users = false
  var order = "totalrank"
  var duration = 0
  var days = 0
  var parameters: [String: String] {
    var result = ["order": users ? "0" : order, "duration": String(duration)]
    if days > 0 { result["pubtime_begin_s"] = String(Int(Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970)); result["pubtime_end_s"] = String(Int(Date().timeIntervalSince1970)) }
    return result
  }
}
struct SearchUser: Identifiable {
  let id: Int
  let name: String
  let face: String
  let bio: String
  let fans: Int
  static func parse(_ raw: [String: Any]) -> Self? {
    guard let mid = raw["mid"] as? Int else { return nil }
    return Self(id: mid, name: raw["uname"] as? String ?? "用户", face: raw["upic"] as? String ?? "",
      bio: raw["usign"] as? String ?? "", fans: raw["fans"] as? Int ?? 0)
  }
}
extension API {
  func searchUsers(_ term: String, page: Int) async throws -> [SearchUser] {
    let data = try await request("/x/web-interface/wbi/search/type", ["search_type": "bili_user", "keyword": term, "page": String(page), "page_size": "24"], signed: true)
    return (data["result"] as? [[String: Any]] ?? []).compactMap(SearchUser.parse)
  }
  func suggestions(_ term: String) async throws -> [String] {
    let data = try await request("/x/web-interface/suggest", ["term": term, "main_ver": "v1", "highlight": "", "func": "suggest", "suggest_type": "accurate", "sub_type": "tag", "tag_num": "8", "pic_num": "0"], signed: true)
    let result = data["result"] as? [String: Any] ?? data
    return (result["tag"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String ?? $0["term"] as? String }
  }
}
#if os(macOS)
struct SearchFilters: View {
  @Bindable var store: Store
  var body: some View {
    HStack(spacing: 14) {
      Picker("搜索类型", selection: $store.searchOptions.users) { Text("视频").tag(false); Text("用户").tag(true) }.pickerStyle(.segmented).frame(width: 160)
      if !store.searchOptions.users {
        Picker("排序", selection: $store.searchOptions.order) {
          Text("综合排序").tag("totalrank"); Text("最多播放").tag("click"); Text("最新发布").tag("pubdate")
          Text("最多弹幕").tag("dm"); Text("最多收藏").tag("stow")
        }.fixedSize()
        Picker("时长", selection: $store.searchOptions.duration) {
          Text("全部时长").tag(0); Text("10分钟以下").tag(1); Text("10–30分钟").tag(2); Text("30–60分钟").tag(3); Text("60分钟以上").tag(4)
        }.fixedSize()
        Picker("发布", selection: $store.searchOptions.days) { Text("全部日期").tag(0); Text("最近一天").tag(1); Text("最近一周").tag(7); Text("最近半年").tag(180) }.fixedSize()
      }
      Spacer(minLength: 0)
    }.onChange(of: store.searchOptions) { store.reload() }
  }
}
struct SearchAssistance: View {
  @Bindable var store: Store
  @State private var suggestions: [String] = []
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack { Text(store.query.isEmpty ? "搜索历史" : "搜索联想").font(.caption).foregroundStyle(.secondary); Spacer()
        if store.query.isEmpty && !store.searchHistory.isEmpty { Button("清空") { store.searchHistory = []; UserDefaults.standard.removeObject(forKey: "searchHistory") }.buttonStyle(.plain).font(.caption) }
      }
      ScrollView(.horizontal) {
        HStack { ForEach(Array((store.query.isEmpty ? store.searchHistory : suggestions).prefix(8)), id: \.self) { term in
          Button(term) { store.query = term; store.search() }.buttonStyle(.appGlassButton)
        } }
      }
    }.padding(12).floatingGlass(18)
      .task(id: store.query) {
        suggestions = []
        guard !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try await Task.sleep(for: .milliseconds(250)); let results = try await store.api.suggestions(store.query); try Task.checkCancellation(); suggestions = Array(Set(results)).sorted() } catch { }
      }
  }
}
struct SearchUserResults: View {
  @Bindable var store: Store
  var body: some View {
    LazyVStack(spacing: 12) { ForEach(store.searchUsers) { user in
      Button { store.showProfile(user.id) } label: {
        HStack(spacing: 16) {
          Thumbnail(url: user.face, mode: .fill, placeholder: "person.crop.circle").frame(width: 56, height: 56).clipShape(.circle)
          VStack(alignment: .leading, spacing: 5) { Text(user.name).font(.headline); Text(user.bio).font(.callout).lineLimit(2).foregroundStyle(.secondary); Text("\(user.fans) 位粉丝").font(.caption).foregroundStyle(.secondary) }
          Spacer(); Image(systemName: "chevron.right")
        }.padding(16).floatingGlass(18).contentShape(.rect(cornerRadius: 18))
      }.buttonStyle(.plain)
    } }
  }
}

#endif
