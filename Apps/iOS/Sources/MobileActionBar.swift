import SwiftUI

struct MobileActionBar: View {
  @Bindable var store: Store
  let detail: Detail
  let interact: (String) -> Void
  @State private var tripleProgress: CGFloat = 0
  @Environment(\.dynamicTypeSize) private var textSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  private var model: VideoActionsModel { store.actions }
  private var identity: String { "\(detail.aid):\(store.api.authenticationGeneration)" }
  private var disabled: Bool {
    detail.aid <= 0 || model.operation != nil || (store.account != nil && (model.loading || model.relation == nil))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: textSize.isAccessibilitySize ? 3 : 5), spacing: 12) {
        Button {
          if store.account == nil { store.login() }
          else { Task { await model.toggleLike(api: store.api) } }
        } label: {
          actionLabel("点赞", count: model.counts.likes,
            icon: model.relation?.liked == true ? "hand.thumbsup.fill" : "hand.thumbsup",
            active: model.relation?.liked == true, animateTriple: true)
        }.buttonStyle(MobileTriplePressStyle(progress: $tripleProgress) {
          guard store.account != nil else { tripleProgress = 0; store.login(); return }
          Task { _ = await model.sendTriple(api: store.api); tripleProgress = 0 }
        }).disabled(disabled).id(identity)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(model.relation?.liked == true ? "已点赞" : "点赞")
          .accessibilityValue(String(model.counts.likes))
          .accessibilityAddTraits(.isButton)
          .accessibilityIdentifier("video-like")
          .accessibilityHint("轻点点赞，按住 1.2 秒三连，最多投 \(detail.copyright == 2 ? 1 : 2) 枚硬币，松开取消")
          .accessibilityAction(named: "一键三连") { interact("triple") }
        Button { interact("coin") } label: {
          actionLabel("投币", count: model.counts.coins, icon: "c.circle",
            active: (model.relation?.coins ?? 0) > 0, animateTriple: true)
        }.disabled(model.operation != nil || model.loading).accessibilityIdentifier("video-coin")
        Button { interact("favorite") } label: {
          actionLabel("收藏", count: model.counts.favorites,
            icon: model.isFavorited ? "star.fill" : "star", active: model.isFavorited, animateTriple: true)
        }.disabled(model.operation != nil).accessibilityIdentifier("video-favorite")
        ShareLink(item: VideoShareLink.make(bvid: detail.video.bvid,
          page: detail.pages.first { $0.id == store.playback.selectedCID }?.number ?? 1,
          seconds: store.playback.positionSeconds)) {
          actionLabel("分享", count: model.counts.shares, icon: "square.and.arrow.up")
        }
        Menu {
          Button("稍后再看") { Task { await addLater(detail.video, store: store) } }
          Button("刷新互动状态") { Task { await refresh() } }
            .disabled(model.loading || model.operation != nil)
        } label: {
          Image(systemName: "ellipsis").frame(maxWidth: .infinity, minHeight: 54).contentShape(Rectangle())
        }.accessibilityLabel("更多视频操作")
      }.buttonStyle(.plain).foregroundStyle(.primary)
      if tripleProgress > 0 || model.operation == "triple" {
        Text(model.operation == "triple" ? "正在三连…" : "按住三连 · 最多 \(detail.copyright == 2 ? 1 : 2) 枚，松开取消")
          .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("triple-progress")
      } else if let notice = model.notice {
        Text(notice).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("interaction-notice")
      }
      if let error = model.error {
        VStack(alignment: .leading, spacing: 8) {
          Text(error).font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("刷新状态") { Task { await refresh() } }
            if model.needsVerification || store.api.appCoinAuthorization != nil {
              Button("重新登录") { store.login() }
            }
            Link("在网页打开", destination: VideoShareLink.make(bvid: detail.video.bvid, page: 1, seconds: nil))
          }.font(.caption).buttonStyle(.appGlassButton).disabled(model.loading || model.operation != nil)
        }
      } else if model.notice != nil && model.relation == nil {
        Button("刷新状态") { Task { await refresh() } }.buttonStyle(.appGlassButton)
      }
    }.onChange(of: identity) { tripleProgress = 0 }
      .onChange(of: scenePhase) { if scenePhase != .active { tripleProgress = 0 } }
      .onDisappear { tripleProgress = 0 }
      .task(id: identity) { await refresh() }
  }
  private func refresh() async { await model.load(detail: detail, accountID: store.account?.mid, api: store.api) }
  private func actionLabel(_ title: String, count: Int, icon: String, active: Bool = false,
                           animateTriple: Bool = false) -> some View {
    VStack(spacing: 6) {
      Image(systemName: icon).font(.system(size: 20)).frame(height: 24)
        .foregroundStyle(active ? biliPink : .primary)
        .symbolEffect(.bounce, value: animateTriple && model.notice == "已三连")
        .symbolEffectsRemoved(reduceMotion)
      Text(count > 0 ? compactCount(count) : title).font(.caption).monospacedDigit().lineLimit(1)
    }.frame(maxWidth: .infinity, minHeight: 54).contentShape(.rect(cornerRadius: AppMetrics.itemRadius))
      .overlay {
        if animateTriple && tripleProgress > 0 {
          RoundedRectangle(cornerRadius: AppMetrics.itemRadius).trim(from: 0, to: tripleProgress)
            .stroke(biliPink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).allowsHitTesting(false)
        }
      }.accessibilityElement(children: .ignore).accessibilityLabel(title + "，" + String(count))
  }
}

private struct MobileTriplePressStyle: PrimitiveButtonStyle {
  @Binding var progress: CGFloat
  let perform: () -> Void
  func makeBody(configuration: Configuration) -> some View {
    MobileTriplePressSurface(label: configuration.label, progress: $progress,
      tap: configuration.trigger, hold: perform)
  }
}
private struct MobileTriplePressSurface<Label: View>: View {
  let label: Label
  @Binding var progress: CGFloat
  let tap: () -> Void
  let hold: () -> Void
  @State private var completed = false
  @State private var pressedAt: Date?
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    label.contentShape(Rectangle())
      .onTapGesture {
        if enabled && !completed && (pressedAt.map { Date().timeIntervalSince($0) < 0.3 } ?? true) { tap() }
      }
      .onLongPressGesture(minimumDuration: 1.2, maximumDistance: 18, perform: {
        guard enabled, !completed, scenePhase == .active else { return }
        completed = true; progress = 1; hold()
      }, onPressingChanged: { pressing in
        if pressing && enabled {
          completed = false; pressedAt = Date(); progress = 0
          withAnimation(reduceMotion ? nil : .linear(duration: 1.2)) { progress = 1 }
        } else if !completed { progress = 0 }
      })
      .accessibilityAction { if enabled { tap() } }
      .onChange(of: scenePhase) { if scenePhase != .active { completed = true; progress = 0 } }
      .onDisappear { completed = true; progress = 0 }
  }
}
