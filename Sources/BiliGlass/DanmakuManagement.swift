import SwiftUI

struct DanmakuManagement: View {
  @Bindable var store: Store
  @Environment(\.dismiss) private var dismiss
  @State private var tab = 0
  @State private var query = ""
  @State private var month = Date()
  @State private var dates: [String] = []
  @State private var day = ""
  @State private var rules: [DanmakuCloudRule] = []
  @State private var ruleText = ""
  @State private var ruleType = 0
  @State private var busy = false
  @State private var error: String?
  @State private var notice: String?
  private var visible: [Danmaku] { store.danmaku.items.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) } }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text("弹幕管理").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
      Picker("弹幕管理分类", selection: $tab) { Text("弹幕列表").tag(0); Text("历史弹幕").tag(1); Text("云端屏蔽").tag(2) }.pickerStyle(.segmented)
      if tab == 2 { cloudControls }
      else {
        if tab == 1 { historyControls }
        HStack {
          TextField("搜索已加载弹幕", text: $query).textFieldStyle(.roundedBorder)
          Text("\(visible.count) 条").font(.caption).foregroundStyle(.secondary)
          if let date = store.danmaku.historyDate { Text(date).font(.caption); Button("恢复当前弹幕") { restoreCurrent() } }
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) { ForEach(visible) { item in
            HStack(alignment: .top, spacing: 12) {
              Button(String(format: "%d:%02d", Int(item.time) / 60, Int(item.time) % 60)) { store.playback.seek(to: item.time) }.font(.caption.monospacedDigit()).buttonStyle(.plain).frame(width: 50)
              Text(item.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
              Menu {
                Button("屏蔽这段文字") { addLocal(item.text) }
                if let hash = item.senderHash { Button("云端屏蔽发送者") { mutateRule(type: 2, text: hash) } }
                Button("举报弹幕…") { report(item) }
              } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }.padding(10).appGlass(10)
          } }
        }
        Text("列表包含当前已经加载的弹幕；点击时间可跳转。").font(.caption).foregroundStyle(.secondary)
      }
      if busy { ProgressView().controlSize(.small) }
      if let error { Text(error).font(.callout).foregroundStyle(.red) }
      if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
    }.padding(24).frame(width: 820, height: 650).background { GlassBackdrop() }
      .sheet(item: $store.danmakuReportTarget) { DanmakuReportForm(store: store, item: $0) }
      .task(id: tab) { if tab == 2 { await loadRules() } else if tab == 1 { await loadCalendar() } }
      .onChange(of: month) { Task { await loadCalendar() } }
  }
  private var historyControls: some View {
    HStack {
      DatePicker("月份", selection: $month, in: ...Date(), displayedComponents: .date).fixedSize()
      Picker("有弹幕的日期", selection: $day) { Text("选择日期").tag(""); ForEach(dates, id: \.self) { Text($0).tag($0) } }.fixedSize()
      Button("查看历史") { loadHistory() }.buttonStyle(.appGlassButton).disabled(day.isEmpty || busy || store.playback.isOffline)
      Spacer()
    }
  }
  private var cloudControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Picker("规则类型", selection: $ruleType) { Text("关键词").tag(0); Text("正则表达式").tag(1); Text("发送者哈希").tag(2) }.fixedSize()
        TextField("屏蔽内容", text: $ruleText).textFieldStyle(.roundedBorder)
        Button("添加") { mutateRule(type: ruleType, text: ruleText) }.buttonStyle(.appGlassButton).disabled(ruleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        Button("同步") { Task { await loadRules() } }.buttonStyle(.appGlassButton).disabled(busy)
      }
      ScrollView { LazyVStack(spacing: 8) { ForEach(rules) { rule in
        HStack { Text(rule.type == 0 ? "关键词" : rule.type == 1 ? "正则" : "发送者").font(.caption).foregroundStyle(.secondary).frame(width: 55); Text(rule.filter).textSelection(.enabled); Spacer(); Button("删除") { removeRule(rule) }.buttonStyle(.appGlassButton).disabled(busy) }.padding(10).appGlass(10)
      } } }
      Text("同步成功后应用于普通弹幕；本机屏蔽词仍单独保留。").font(.caption).foregroundStyle(.secondary)
    }
  }
  private func addLocal(_ text: String) {
    var words = UserDefaults.standard.string(forKey: "danmakuBlockedWords")?.components(separatedBy: "\n") ?? []
    if !words.contains(text) { words.append(text) }; UserDefaults.standard.set(words.joined(separator: "\n"), forKey: "danmakuBlockedWords"); notice = "已加入本机屏蔽词"
  }
  private func loadRules() async {
    guard !busy else { return }; busy = true; error = nil; defer { busy = false }
    do { rules = try await store.api.cloudDanmakuRules() } catch { self.error = error.localizedDescription }
  }
  private func mutateRule(type: Int, text: String) {
    guard !busy, !text.isEmpty else { return }; busy = true; error = nil
    Task {
      do { _ = try await store.api.post("/x/dm/filter/user/add", ["type": String(type), "filter": text]); rules = try await store.api.cloudDanmakuRules(); ruleText = ""; notice = "已更新云端屏蔽" }
      catch { self.error = error.localizedDescription }; busy = false
    }
  }
  private func removeRule(_ rule: DanmakuCloudRule) {
    guard !busy else { return }; busy = true; error = nil
    Task { do { _ = try await store.api.post("/x/dm/filter/user/del", ["ids": String(rule.id)]); rules = try await store.api.cloudDanmakuRules() } catch { self.error = error.localizedDescription }; busy = false }
  }
  private func loadCalendar() async {
    guard !busy, store.api.signedIn else { if !store.api.signedIn { error = "登录后查看历史弹幕" }; return }
    busy = true; error = nil; defer { busy = false }
    do {
      let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 28800); formatter.dateFormat = "yyyy-MM"
      let data = try await store.api.request("/x/v2/dm/history/index", ["type": "1", "oid": String(store.playback.selectedCID), "month": formatter.string(from: month)])
      dates = data["items"] as? [String] ?? []; day = dates.last ?? ""
      if dates.isEmpty { notice = "这个月没有可用的历史弹幕" }
    } catch { self.error = error.localizedDescription }
  }
  private func loadHistory() {
    guard !busy else { return }; busy = true; error = nil
    let cid = store.playback.selectedCID, date = day
    Task {
      do {
        let data = try await store.api.binary("/x/v2/dm/web/history/seg.so", ["type": "1", "oid": String(cid), "date": date])
        let items = try await Task.detached(priority: .userInitiated) { try ProtoReader.decode(data) }.value
        guard cid == store.playback.selectedCID else { busy = false; return }
        store.danmaku.stop(); store.danmaku.items = items; store.danmaku.historyDate = date; notice = "已切换到 \(date) 的弹幕"
      } catch { self.error = error.localizedDescription }; busy = false
    }
  }
  private func restoreCurrent() { store.danmaku.start(cid: store.playback.selectedCID, aid: store.playback.detail?.aid ?? 0, api: store.api, player: store.playback.player, localSidecar: store.playback.localDanmaku) }
  private func report(_ item: Danmaku) {
    store.danmakuReportTarget = item
  }
}
struct DanmakuReportForm: View {
  @Bindable var store: Store
  let item: Danmaku
  @Environment(\.dismiss) private var dismiss
  @State private var reason = 1
  @State private var description = ""
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("举报弹幕").font(.title2.bold()); Text(item.text).lineLimit(3)
      Picker("原因", selection: $reason) { Text("违法违禁").tag(1); Text("色情低俗").tag(2); Text("赌博诈骗").tag(3); Text("人身攻击").tag(4); Text("侵犯隐私").tag(5); Text("垃圾广告").tag(6); Text("引战").tag(7); Text("剧透").tag(8); Text("恶意刷屏").tag(9); Text("视频无关").tag(10); Text("其他").tag(11); Text("青少年不良信息").tag(12) }
      TextField("补充说明", text: $description, axis: .vertical).lineLimit(3...5).textFieldStyle(.roundedBorder)
      if let error { Text(error).foregroundStyle(.red) }
      HStack { Button("取消") { dismiss() }; Spacer(); Button("提交举报") { submit() }.disabled(busy) }.buttonStyle(.appGlassButton)
    }.padding(24).frame(width: 450)
  }
  private func submit() {
    busy = true; error = nil
    let cid = store.playback.selectedCID
    Task { do { _ = try await store.api.post("/x/dm/report/add", ["cid": String(cid), "dmid": item.id, "reason": String(reason), "content": description]); store.interactionMessage = "弹幕举报已提交"; dismiss() } catch { self.error = error.localizedDescription }; busy = false }
  }
}
