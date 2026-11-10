import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

private enum VideoActionSheet: String, Identifiable {
  case coin, triple, favorite, share
  var id: String { rawValue }
}

struct WatchLaterButton: View {
  @Bindable var store: Store
  let aid: Int
  var body: some View {
    Button {
      guard store.account != nil else { store.login(); return }
      Task { await store.addLater(aid) }
    } label: {
      Label("稍后再看", systemImage: "text.badge.plus")
        .font(.callout).padding(4).contentShape(.rect)
    }.buttonStyle(InterfacePressStyle()).foregroundStyle(.secondary)
      .help("稍后再看").accessibilityLabel("稍后再看")
  }
}

struct VideoActionBar: View {
  @Bindable var store: Store
  let detail: Detail
  var showsPlaybackOptions = false
  @State private var sheet: VideoActionSheet?
  @State private var loginAfterDismiss = false
  @State private var tripleProgress: CGFloat = 0
  @State private var danmakuManager = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var model: VideoActionsModel { store.videoActions }
  private var identity: String { "\(detail.aid):\(store.account?.mid ?? 0):\(store.api.authenticationGeneration)" }
  private var disabled: Bool { detail.aid <= 0 || model.operation != nil || (store.account != nil && (model.loading || model.relation == nil)) }
  private var showsFooter: Bool {
    showsPlaybackOptions || model.loading || tripleProgress > 0 || model.operation == "triple" || model.notice != nil
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      GlassEffectContainer(spacing: 10) {
        HStack(spacing: 10) {
          action(title: model.relation?.liked == true ? "已点赞" : "点赞", icon: model.relation?.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup",
                 count: model.counts.likes, active: model.relation?.liked == true, busy: model.operation == "like", holdToTriple: true) {
            authenticated { Task { await model.toggleLike(api: store.api) } }
          }.disabled(disabled).help("点击点赞，按住 1.2 秒完成三连")
          action(title: (model.relation?.coins ?? 0) > 0 ? "已投 \(model.relation!.coins) 枚" : "投币", icon: "c.circle",
                 count: model.counts.coins, active: (model.relation?.coins ?? 0) > 0) { authenticated { sheet = .coin } }.disabled(disabled)
          action(title: model.relation?.favorited == true ? "已收藏" : "收藏", icon: model.relation?.favorited == true ? "star.fill" : "star",
                 count: model.counts.favorites, active: model.relation?.favorited == true) { authenticated { sheet = .favorite } }.disabled(disabled)
          action(title: "分享", icon: "square.and.arrow.up", count: model.counts.shares) { sheet = .share }
        }
      }
      .contextMenu {
        if store.account != nil {
          Button("刷新互动状态") { Task { await refresh() } }
            .disabled(model.loading || model.operation != nil)
        }
      }
      if showsFooter {
        HStack(spacing: 12) {
          if showsPlaybackOptions { WatchLaterButton(store: store, aid: detail.aid) }
          if store.account != nil {
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
              .help("刷新互动状态").accessibilityLabel("刷新互动状态").disabled(model.loading || model.operation != nil)
          }
          if model.loading { ProgressView().controlSize(.small); Text("同步状态").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
          if tripleProgress > 0 || model.operation == "triple" {
            Text(model.operation == "triple" ? "正在三连…" : "按住三连 · 最多 \(detail.copyright == 2 ? 1 : 2) 枚，松开取消")
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
          } else if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary).lineLimit(1).transition(.opacity) }
          Spacer(minLength: 4)
          if showsPlaybackOptions {
            PlaybackOptionsControls(store: store, onShowDanmakuList: { danmakuManager = true })
              .transition(.opacity)
          }
        }.buttonStyle(.glass)
          .interfaceAnimation(showsPlaybackOptions)
      }
      if let error = model.error {
        HStack {
          Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
          if model.needsVerification {
            Button("重新登录") { store.login() }
          }
        }.buttonStyle(.glass)
      }
    }.task(id: identity) { await refresh() }
      .onChange(of: identity) { sheet = nil; tripleProgress = 0 }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.relation)
      .sheet(isPresented: $danmakuManager) { DanmakuManagement(store: store) }
      .sheet(item: $sheet, onDismiss: {
        if loginAfterDismiss { loginAfterDismiss = false; store.login() }
      }) { target in
        switch target {
        case .coin: CoinSheet(store: store, detail: detail) {
          loginAfterDismiss = true
          sheet = nil
        }
        case .triple: TripleSheet(store: store, detail: detail) {
          loginAfterDismiss = true; sheet = nil
        }
        case .favorite: FavoriteSheet(store: store, detail: detail)
        case .share: VideoShareSheet(store: store, detail: detail)
        }
      }
  }
  private func refresh() async { await model.load(detail: detail, accountID: store.account?.mid, api: store.api) }
  private func authenticated(_ action: () -> Void) { if store.account == nil { store.login() } else { action() } }
  private func action(title: String, icon: String, count: Int, active: Bool = false, busy: Bool = false, holdToTriple: Bool = false, perform: @escaping () -> Void) -> some View {
    let button = Button(action: perform) {
      HStack(spacing: 10) {
        if busy { ProgressView().controlSize(.small).frame(width: 22) }
        else { Image(systemName: icon).font(.title3).frame(width: 22) }
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.callout.weight(.medium))
          Text(count >= 10000 ? String(format: "%.1f万", Double(count) / 10000) : String(count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }.padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, minHeight: 40).contentShape(.rect(cornerRadius: 18))
    }.foregroundStyle(.primary).tint(.primary)
      .glassEffect(.regular.tint(active ? biliPink.opacity(0.22) : .clear).interactive(), in: .rect(cornerRadius: 18))
      .overlay {
        if icon != "square.and.arrow.up" && tripleProgress > 0 {
          RoundedRectangle(cornerRadius: 18).trim(from: 0, to: tripleProgress)
            .stroke(biliPink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).allowsHitTesting(false)
        }
      }
      .accessibilityLabel(title).accessibilityValue("\(count)")
    return Group {
      if holdToTriple {
        button.buttonStyle(TriplePressStyle(progress: $tripleProgress, perform: {
          guard store.account != nil else { tripleProgress = 0; store.login(); return }
          Task { _ = await model.sendTriple(api: store.api); tripleProgress = 0 }
        }))
        .accessibilityAction(named: "一键三连") { authenticated { sheet = .triple } }
      } else { button.buttonStyle(NavigationButtonStyle()) }
    }
  }
}

private struct TriplePressStyle: PrimitiveButtonStyle {
  @Binding var progress: CGFloat
  let perform: () -> Void
  func makeBody(configuration: Configuration) -> some View {
    TriplePressSurface(label: configuration.label, progress: $progress, tap: configuration.trigger, hold: perform)
  }
}
private struct TriplePressSurface<Label: View>: View {
  let label: Label
  @Binding var progress: CGFloat
  let tap: () -> Void
  let hold: () -> Void
  @State private var completed = false
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    label.contentShape(Rectangle())
      .onTapGesture { if enabled && !completed { tap() } }
      .onLongPressGesture(minimumDuration: 1.2, maximumDistance: 18, perform: {
        guard enabled, !completed else { return }
        completed = true
        progress = 1
        hold()
      }, onPressingChanged: { pressing in
        if pressing && enabled {
          completed = false
          progress = 0
          withAnimation(reduceMotion ? nil : .linear(duration: 1.2)) { progress = 1 }
        } else if !completed { progress = 0 }
      })
      .accessibilityAction { if enabled { tap() } }
      .onDisappear { progress = 0 }
  }
}

private struct InteractionVerification: View {
  let store: Store
  let detail: Detail
  @State private var useWebsite = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(useWebsite ? "官网互动" : "官方验证").font(.headline)
        Spacer()
        if !useWebsite, store.videoActions.challenge != nil {
          Button("在官网继续") { useWebsite = true }
        }
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }.padding(14)
      if let challenge = store.videoActions.challenge, !useWebsite {
        OfficialChallengeView(api: store.api, challenge: challenge) {
          store.videoActions.verificationCompleted()
          dismiss()
        }
      } else {
        OfficialWebPanel(target: WebTarget(url: VideoShareLink.make(bvid: detail.video.bvid, page: 1, seconds: nil), title: "互动验证"), api: store.api)
      }
    }.frame(minWidth: 640, idealWidth: 1000, minHeight: 560, idealHeight: 720)
  }
}

struct CoinSheet: View {
  @Bindable var store: Store
  let detail: Detail
  let relogin: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var amount = 1
  @State private var alsoLike = false
  @State private var balance: Double?
  @State private var preparing = true
  @State private var localError: String?
  private var model: VideoActionsModel { store.videoActions }
  private var limit: Int { detail.copyright == 2 ? 1 : 2 }
  private var choice: CoinAvailability { CoinAvailability(limit: limit, coins: model.relation?.coins, balance: balance) }
  private var available: Int { choice.available }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var busy: Bool { preparing || model.loading || model.operation != nil }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack { Label("投币", systemImage: "c.circle").font(.title2.weight(.semibold)); Spacer(); Button("关闭") { dismiss() }.disabled(model.operation != nil).keyboardShortcut(.cancelAction) }
      Text(detail.video.title).font(.headline).lineLimit(2)
      VStack(spacing: 18) {
        HStack { Text("我的硬币"); Spacer(); Text(balance.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—").monospacedDigit() }
        HStack { Text("本视频已投"); Spacer(); Text(model.relation.map { "\($0.coins) / \(limit) 枚" } ?? "—").monospacedDigit() }
        Divider()
        HStack(spacing: 12) {
          ForEach(1...2, id: \.self) { value in
            Button { amount = value } label: {
              VStack(spacing: 8) { Image(systemName: "c.circle").font(.largeTitle); Text("\(value) 枚").font(.headline) }
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .contentShape(.rect(cornerRadius: 18))
            }.buttonStyle(.plain).foregroundStyle(.primary)
              .glassEffect(.regular.tint(amount == value ? biliPink.opacity(0.24) : .clear).interactive(), in: .rect(cornerRadius: 18))
              .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(amount == value ? biliPink.opacity(0.8) : .clear, lineWidth: 1.5).allowsHitTesting(false) }
              .accessibilityAddTraits(amount == value ? .isSelected : [])
              .opacity(value > available ? 0.45 : 1)
              .help(busy ? "正在读取或提交投币状态" : choice.reason(for: value) ?? "选择 \(value) 枚硬币")
              .accessibilityHint(choice.reason(for: value) ?? "")
              .disabled(value > available || busy || model.relation == nil)
          }
        }
        if !preparing, let reason = choice.reason(for: 2) {
          Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if model.relation?.liked != true {
          Toggle("同时点赞", isOn: $alsoLike).toggleStyle(.switch).disabled(busy)
        }
      }.padding(20).floatingGlass(22)
      if preparing { ProgressView("正在读取投币状态") }
      else if available == 0, model.relation != nil, balance != nil {
        Text((model.relation?.coins ?? 0) >= limit ? "本视频已投满" : "硬币余额不足").foregroundStyle(.secondary)
      }
      if let error = localError ?? model.error { Text(error).font(.callout).foregroundStyle(.secondary) }
      if model.needsVerification || (model.error != nil && store.api.appCoinAuthorization != nil) {
        Button("重新登录", action: relogin).disabled(busy)
      }
      Text("投币后无法撤回。").font(.caption).foregroundStyle(.secondary)
      HStack {
        if localError != nil || model.error != nil || (!preparing && model.relation == nil) {
          Button("刷新状态") { Task { await prepare() } }.disabled(busy)
          Button("在网页打开") {
            NSWorkspace.shared.open(VideoShareLink.make(bvid: detail.video.bvid, page: 1, seconds: nil))
          }.disabled(busy)
        }
        Spacer()
        Button(model.operation == "coin" ? "提交中…" : "投 \(amount) 枚") {
          Task {
            if await model.sendCoins(amount: amount, limit: limit, balance: balance ?? 0, alsoLike: alsoLike, api: store.api) { dismiss() }
          }
        }.buttonStyle(.glassProminent).disabled(busy || model.relation == nil || amount > available || balance == nil)
      }
    }.buttonStyle(.glass).padding(24).frame(width: 440).background { GlassBackdrop() }.tint(biliPink)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: amount)
      .interactiveDismissDisabled(model.operation != nil)
      .task { await prepare() }
  }
  private func prepare() async {
    preparing = true; balance = nil; localError = nil
    defer { preparing = false }
    let session = store.api.authenticationGeneration
    await model.load(detail: detail, accountID: store.account?.mid, api: store.api)
    do {
      let result = try await store.api.request("/x/web-interface/nav")
      guard !Task.isCancelled, session == store.api.authenticationGeneration else { return }
      guard let money = result["money"] as? Double, money.isFinite else { throw BiliError(text: "未能读取硬币余额，请刷新") }
      balance = max(0,money); amount = min(max(1,available),amount)
    } catch { if !Task.isCancelled { localError = error.localizedDescription } }
    preparing = false
  }
}

struct TripleSheet: View {
  @Bindable var store: Store
  let detail: Detail
  let relogin: () -> Void
  @Environment(\.dismiss) private var dismiss
  private var model: VideoActionsModel { store.videoActions }
  private var busy: Bool { model.operation != nil || model.loading }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack { Label("一键三连", systemImage: "hand.thumbsup.circle").font(.title2.weight(.semibold))
        Spacer(); Button("关闭") { dismiss() }.disabled(busy).keyboardShortcut(.cancelAction) }
      Text(detail.video.title).font(.headline).lineLimit(2)
      VStack(alignment: .leading, spacing: 14) {
        Label("点赞", systemImage: "hand.thumbsup")
        Label(detail.copyright == 2 ? "投币，最多 1 枚" : "投币，最多 2 枚", systemImage: "c.circle")
        Label("收藏到默认收藏夹", systemImage: "star")
      }.frame(maxWidth: .infinity, alignment: .leading).padding(20).floatingGlass(22)
      Text("已完成的操作由服务器判断。投币后无法撤回。").font(.caption).foregroundStyle(.secondary)
      if let error = model.error { Text(error).font(.callout).foregroundStyle(.secondary) }
      HStack {
        if model.error != nil {
          Button("刷新状态") { Task { await refresh() } }.disabled(busy)
          if model.needsVerification || store.api.appCoinAuthorization != nil {
            Button("重新登录", action: relogin).disabled(busy)
          }
        }
        Spacer()
        Button(model.operation == "triple" ? "提交中…" : "确认三连") {
          Task { if await model.sendTriple(api: store.api) { dismiss() } }
        }.buttonStyle(.glassProminent).disabled(busy || model.relation == nil)
      }
    }.buttonStyle(.glass).padding(24).frame(width: 440).background { GlassBackdrop() }.tint(biliPink)
      .interactiveDismissDisabled(busy)
      .task { await refresh() }
  }
  private func refresh() async { await model.load(detail: detail, accountID: store.account?.mid, api: store.api) }
}

struct FavoriteSheet: View {
  @Bindable var store: Store
  let detail: Detail
  @State private var editor: FavoriteEditor
  @State private var creating = false
  @State private var name = ""
  @State private var isPrivate = false
  @State private var verify = false
  @Environment(\.dismiss) private var dismiss
  init(store: Store, detail: Detail) {
    self.store = store; self.detail = detail
    _editor = State(initialValue: FavoriteEditor(aid: detail.aid, mid: store.account?.mid ?? 0))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text("收藏到").font(.title2.weight(.semibold)); Spacer(); Button("取消") { dismiss() }.disabled(editor.saving).keyboardShortcut(.cancelAction) }
      Text(detail.video.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
      if editor.loading { ProgressView("正在读取收藏夹").frame(maxWidth: .infinity).padding(24) }
      else {
        ScrollView {
          LazyVStack(spacing: 10) {
            if editor.folders.isEmpty, editor.loaded { Text("还没有收藏夹").foregroundStyle(.secondary).padding(24) }
            ForEach(editor.folders) { folder in
              Button {
                if editor.selected.contains(folder.id) { editor.selected.remove(folder.id) }
                else { editor.selected.insert(folder.id) }
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: editor.selected.contains(folder.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(editor.selected.contains(folder.id) ? biliPink : .secondary)
                  Image(systemName: folder.isPrivate ? "lock" : "folder")
                  Text(folder.title).lineLimit(2)
                  Spacer()
                  Text("\(folder.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(14).frame(maxWidth: .infinity).contentShape(.rect(cornerRadius: 16))
              }.buttonStyle(.plain).floatingGlass(16).disabled(editor.saving || !editor.loaded)
                .accessibilityAddTraits(editor.selected.contains(folder.id) ? .isSelected : [])
            }
          }.padding(4)
        }.frame(minHeight: 120, maxHeight: 280)
      }
      if editor.loaded { Text("已选 \(editor.selected.count) 个收藏夹 · 取消勾选可移除收藏").font(.caption).foregroundStyle(.secondary) }
      if creating {
        VStack(spacing: 12) {
          TextField("收藏夹名称（最多 20 字）", text: $name).textFieldStyle(.roundedBorder)
          HStack {
            Toggle("私密收藏夹", isOn: $isPrivate).toggleStyle(.switch)
            Spacer()
            Button("创建") { Task { if await editor.create(title: name, isPrivate: isPrivate, api: store.api) { creating = false; name = "" } } }
              .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 20 || editor.saving || !editor.loaded)
          }
        }.padding(16).floatingGlass(18)
      }
      if let error = editor.error { Text(error).font(.callout).foregroundStyle(.secondary) }
      HStack {
        Button(creating ? "收起新建" : "新建收藏夹") { creating.toggle() }.disabled(editor.saving || !editor.loaded)
        Button { Task { await editor.load(api: store.api) } } label: { Image(systemName: "arrow.clockwise") }.help("刷新收藏夹").accessibilityLabel("刷新收藏夹").disabled(editor.saving || editor.loading)
        if editor.needsVerification { Button("完成验证") { verify = true }.disabled(editor.saving) }
        Spacer()
        Button(editor.saving ? "保存中…" : "保存") {
          Task {
            if await editor.save(api: store.api) {
              store.folders = editor.folders
              store.videoActions.favoritesSaved(aid: detail.aid, isFavorite: !editor.selected.isEmpty)
              dismiss()
            }
          }
        }.buttonStyle(.glassProminent).disabled(editor.loading || editor.saving || !editor.loaded)
      }
    }.buttonStyle(.glass).padding(24).frame(width: 500).background { GlassBackdrop() }.tint(biliPink)
      .interactiveDismissDisabled(editor.saving)
      .task { await editor.load(api: store.api) }
      .sheet(isPresented: $verify, onDismiss: { Task { await editor.load(api: store.api) } }) { InteractionVerification(store: store, detail: detail) }
  }
}

struct VideoShareSheet: View {
  let store: Store
  let detail: Detail
  @Environment(\.dismiss) private var dismiss
  @State private var includeTime = false
  @State private var seconds = 0.0
  @State private var copied: String?
  private var page: Int { detail.pages.first(where: { $0.id == store.playback.selectedCID })?.number ?? 1 }
  private var url: URL { VideoShareLink.make(bvid: detail.video.bvid, page: page, seconds: includeTime ? seconds : nil) }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack { Label("分享视频", systemImage: "square.and.arrow.up").font(.title2.weight(.semibold)); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
      Text(detail.video.title).font(.headline).lineLimit(2)
      HStack(spacing: 24) {
        if let qr = qrImage {
          Image(nsImage: qr).interpolation(.none).resizable().frame(width: 148, height: 148).padding(10).background(.white, in: .rect(cornerRadius: 14))
            .accessibilityLabel("视频链接二维码")
        }
        VStack(alignment: .leading, spacing: 16) {
          Text("扫码打开视频").font(.headline)
          Text(page > 1 ? "第 \(page) 集 · \(detail.video.bvid)" : detail.video.bvid).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
          Toggle("从 \(timestamp) 开始", isOn: $includeTime).toggleStyle(.switch)
          Button("使用当前播放位置") { captureTime() }.font(.callout)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.padding(18).floatingGlass(22)
      Text(url.absoluteString).font(.callout).textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading).appGlass(14)
      HStack {
        Button("复制 BV 号") { copy(detail.video.bvid, notice: "BV 号已复制") }
        Button("复制链接") { copy(url.absoluteString, notice: "链接已复制") }
        Spacer()
        ShareLink(item: url, subject: Text(detail.video.title), message: Text(detail.video.title)) { Label("系统分享", systemImage: "square.and.arrow.up") }
      }
      if let copied { Text(copied).font(.caption).foregroundStyle(.secondary) }
    }.buttonStyle(.glass).padding(24).frame(width: 560).background { GlassBackdrop() }.tint(biliPink)
      .onAppear { captureTime() }.onChange(of: url) { copied = nil }
  }
  private var timestamp: String { let value = Int(max(0,seconds)); return String(format: "%d:%02d",value/60,value%60) }
  private func captureTime() { let value = store.playback.player.currentTime().seconds; seconds = value.isFinite ? min(604800,max(0,value)) : 0 }
  private func copy(_ value: String, notice: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string); copied = notice }
  private var qrImage: NSImage? {
    let filter = CIFilter.qrCodeGenerator(); filter.message = Data(url.absoluteString.utf8)
    guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
      let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: 148, height: 148))
  }
}
