import SwiftUI

enum StartPage: String, CaseIterable, Identifiable {
  case recommend, popular, regions, dynamic, messages, history, favorites, later, downloads, profile, web
  var id: String { rawValue }
  var title: String {
    switch self {
    case .recommend: "推荐"
    case .popular: "热门"
    case .regions: "分区"
    case .dynamic: "关注动态"
    case .messages: "消息"
    case .history: "观看记录"
    case .favorites: "收藏"
    case .later: "稍后再看"
    case .downloads: "下载"
    case .profile: "我的主页"
    case .web: "更多"
    }
  }
  var symbol: String {
    switch self {
    case .recommend: "house"
    case .popular: "flame"
    case .regions: "square.grid.2x2"
    case .dynamic: "person.2"
    case .messages: "bubble.left.and.bubble.right"
    case .history: "clock"
    case .favorites: "star"
    case .later: "text.badge.plus"
    case .downloads: "arrow.down.circle"
    case .profile: "person.crop.circle"
    case .web: "ellipsis.circle"
    }
  }
  var phoneTab: Int {
    if isHome { return 0 }
    if self == .dynamic { return 1 }
    if self == .messages { return 2 }
    if isLibrary { return 3 }
    return 4
  }
  var isHome: Bool { [.recommend, .popular, .regions].contains(self) }
  var isLibrary: Bool { [.history, .favorites, .later, .downloads].contains(self) }
  var isBrowse: Bool { isHome || self == .dynamic || self == .messages }
  static var supported: [Self] {
    #if os(iOS)
      allCases.filter { $0 != .web }
    #else
      allCases
    #endif
  }
}

struct BrowsePreferences: Equatable {
  var showRecommended: Bool
  var showPopular: Bool
  var start: StartPage
  var hidden: Set<StartPage>
  var order: [StartPage]
  init(defaults: UserDefaults = .standard) {
    self.init(recommended: defaults.object(forKey: "showRecommended") == nil || defaults.bool(forKey: "showRecommended"),
      popular: defaults.object(forKey: "showPopular") == nil || defaults.bool(forKey: "showPopular"),
      start: defaults.string(forKey: "startPage") ?? "recommend",
      hidden: defaults.string(forKey: "hiddenNavigationItems") ?? "",
      order: defaults.string(forKey: "navigationItemOrder") ?? "")
  }
  init(recommended: Bool, popular: Bool, start: String, hidden: String, order: String) {
    showRecommended = recommended; showPopular = popular
    self.start = StartPage(rawValue: start) ?? .recommend
    self.hidden = Set(hidden.split(separator: ",").compactMap { StartPage(rawValue: String($0)) })
    var seen = Set<StartPage>()
    self.order = (order.split(separator: ",").compactMap { StartPage(rawValue: String($0)) } + StartPage.supported)
      .filter { StartPage.supported.contains($0) && seen.insert($0).inserted }
  }
  func allows(_ page: StartPage) -> Bool {
    StartPage.supported.contains(page) && !hidden.contains(page)
      && (page != .recommend || showRecommended) && (page != .popular || showPopular)
  }
  var visible: [StartPage] { order.filter { allows($0) } }
  var phoneTabs: [Int] {
    var seen = Set<Int>()
    return (visible.map(\.phoneTab) + [4]).filter { seen.insert($0).inserted }
  }
  // Corrupt/imported preferences must still leave a reachable page.
  var resolvedStart: StartPage { allows(start) ? start : allows(.history) ? .history : visible.first ?? .profile }
}

/// Shared observable preferences keep every navigation surface in sync immediately.
struct NavigationCustomization: DynamicProperty {
  @AppStorage("showRecommended") var recommended = true
  @AppStorage("showPopular") var popular = true
  @AppStorage("startPage") var start = StartPage.recommend.rawValue
  @AppStorage("hiddenNavigationItems") var hidden = ""
  @AppStorage("navigationItemOrder") var order = ""
  var preferences: BrowsePreferences {
    BrowsePreferences(recommended: recommended, popular: popular, start: start, hidden: hidden, order: order)
  }
  func setVisible(_ page: StartPage, _ visible: Bool) {
    var items = preferences.hidden
    if visible { items.remove(page) } else { items.insert(page) }
    if page == .recommend { recommended = visible }
    if page == .popular { popular = visible }
    hidden = StartPage.supported.filter { items.contains($0) }.map(\.rawValue).joined(separator: ",")
    start = preferences.resolvedStart.rawValue
  }
  func move(_ page: StartPage, by delta: Int) {
    var items = preferences.order
    guard let index = items.firstIndex(of: page), items.indices.contains(index + delta) else { return }
    items.swapAt(index, index + delta)
    order = items.map(\.rawValue).joined(separator: ",")
  }
  func reset() {
    recommended = true; popular = true; hidden = ""; order = ""; start = "recommend"
  }
}

struct BrowsePreferenceFields: View {
  private var navigation = NavigationCustomization()
  @AppStorage("refreshHomeOnReturn") private var refresh = false
  var body: some View {
    Picker("启动时打开", selection: navigation.$start) {
      ForEach(navigation.preferences.visible) { Text($0.title).tag($0.rawValue) }
    }.accessibilityIdentifier("start-page")
    Toggle("返回首页时自动刷新", isOn: $refresh).accessibilityIdentifier("refresh-home-on-return")
    Text("关闭时保留推荐列表和浏览位置；开启后返回推荐首页会刷新并回到顶部。热门和分区不受影响。")
      .font(.caption).foregroundStyle(.secondary)
    DisclosureGroup("自定义导航项目") {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(navigation.preferences.order) { page in
          HStack(spacing: 8) {
            Toggle(page.title, isOn: Binding(get: { navigation.preferences.allows(page) },
              set: { navigation.setVisible(page, $0) }))
              .frame(maxWidth: .infinity, alignment: .leading)
              .disabled(navigation.preferences.visible.count == 1 && navigation.preferences.allows(page))
              .accessibilityIdentifier("show-\(page == .recommend ? "recommended" : page.rawValue)")
            Button { navigation.move(page, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 36, height: 36).contentShape(.rect) }
              .disabled(navigation.preferences.order.first == page)
              .accessibilityLabel("上移\(page.title)").accessibilityIdentifier("move-up-\(page.rawValue)")
            Button { navigation.move(page, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 36, height: 36).contentShape(.rect) }
              .disabled(navigation.preferences.order.last == page)
              .accessibilityLabel("下移\(page.title)").accessibilityIdentifier("move-down-\(page.rawValue)")
          }.buttonStyle(.borderless)
        }
      }.padding(.vertical, 8).interfaceAnimation(navigation.preferences.order)
    }
    Text("可隐藏或调整每组内的顺序；手机底栏按各组第一个项目的位置排序。设置与登录入口始终保留，隐藏启动页后优先打开观看记录。")
      .font(.caption).foregroundStyle(.secondary)
    Button("恢复首页与导航默认设置") { navigation.reset(); refresh = false }
  }
}

/// Only the saved offset belongs to the session. Two transitioning scroll
/// views must not share a live ScrollPosition binding and overwrite each other.
@MainActor @Observable final class BrowsePosition {
  var offset: CGFloat = 0
  var resetRevision = 0
  func reset() { offset = 0; resetRevision += 1 }
}

struct RememberedScroll: ViewModifier {
  @Bindable var memory: BrowsePosition
  var tracking = true
  @State private var position = ScrollPosition(y: 0)
  @State private var userScrolling = false
  func body(content: Content) -> some View {
    content.scrollPosition($position)
      .onScrollPhaseChange { _, phase in
        userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
      }
      .onScrollGeometryChange(for: CGFloat.self) { max(0, $0.contentOffset.y + $0.contentInsets.top) } action: { _, y in
        if tracking && userScrolling { memory.offset = y }
      }
      .onAppear { restore() }
      .onChange(of: memory.resetRevision) { restore() }
  }
  private func restore() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { position.scrollTo(y: memory.offset) }
  }
}

/// Keep the phone navigation on both folded and expanded phone displays.
/// Only iPad uses the sidebar layout.
enum AdaptiveNavigationLayout {
  static func usesColumns(width: CGFloat, height: CGFloat, isTablet: Bool) -> Bool {
    isTablet
  }
}
