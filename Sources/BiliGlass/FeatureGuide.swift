import AppKit
import SwiftUI

/// Capture existing preferences before views register defaults. Receipts live in
/// the app domain, so replacing the application bundle does not reset them.
@MainActor final class GuideHistory {
  enum Presentation: Equatable { case tutorial, update(previous: String?) }
  let defaults: UserDefaults
  let version: String
  let revision: String
  private let existingInstallation: Bool
  init(defaults: UserDefaults = .standard, version: String = GuideContent.version,
       revision: String = GuideContent.revision) {
    self.defaults = defaults; self.version = version; self.revision = revision
    existingInstallation = ["guideLastVersion", "history", "homeFeedSnapshot", "searchHistory",
      "appearance", "videoThreads", "downloadThreads", "quality", "cacheDirectory"]
      .contains { defaults.object(forKey: $0) != nil }
  }
  func pending(hasSavedLogin: Bool) -> Presentation? {
    guard !(defaults.stringArray(forKey: "guidePresentedEditions") ?? []).contains(version + ":" + revision) else { return nil }
    return existingInstallation || hasSavedLogin
      ? .update(previous: defaults.string(forKey: "guideLastVersion")) : .tutorial
  }
  func didPresent() {
    var editions = defaults.stringArray(forKey: "guidePresentedEditions") ?? []
    let edition = version + ":" + revision
    if !editions.contains(edition) { editions.append(edition) }
    defaults.set(editions, forKey: "guidePresentedEditions")
    defaults.set(version, forKey: "guideLastVersion")
  }
}

enum LoginUpgradeReason: Equatable {
  case missingAuthorization, expiredAuthorization
  static func evaluate(cookies: [String: String], authorization: AppCoinAuthorization?, now: Date = Date()) -> Self? {
    guard cookies["SESSDATA"]?.isEmpty == false else { return nil }
    guard let authorization else { return .missingAuthorization }
    return authorization.isValid(for: cookies["DedeUserID"], now: now) ? nil : .expiredAuthorization
  }
  var message: String {
    switch self {
    case .missingAuthorization: "旧版登录未包含客户端投币授权。重新扫码一次后可使用投币和长按三连。"
    case .expiredAuthorization: "客户端投币授权已过期或与当前账号不匹配。重新扫码可更新登录。"
    }
  }
}

struct GuidePage: Identifiable {
  let id: String
  let title: String
  let location: String
  let symbol: String
  let paragraphs: [String]
  var settingsTab: Int? = nil
}

enum GuideContent {
  static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.3"
  // Increment only when guide content changes, not on every build.
  static let revision = "2026-10-28-release-1.1.3"
  static let tutorial: [GuidePage] = [
    .init(id: "account", title: "登录与账号", location: "左下角账号菜单", symbol: "person.crop.circle", paragraphs: [
      "点击“登录”，用哔哩哔哩 App 扫描二维码，并在手机上确认。同一次扫码会完成浏览与互动所需的登录，凭证保存在本机钥匙串。",
      "从旧版升级后，如果提示更新登录，点击“重新登录”即可。取消扫码会保留原登录；扫码本身不会投币。",
      "账号菜单提供个人主页、设置、重新登录和退出登录。未登录时可以浏览公开内容，账号功能和部分清晰度需要登录。"]),
    .init(id: "browse", title: "浏览与搜索", location: "左侧浏览菜单 · 顶部搜索框", symbol: "magnifyingglass", paragraphs: [
      "推荐、热门、分区和关注动态分别提供视频列表。输入关键词搜索视频或用户，也可以粘贴 BV 号或视频链接直接打开。搜索页可调整排序、时长和时间范围。",
      "列表向下滚动时自动加载下一页。可以在“设置 → 外观与交互”关闭自动加载，改用“加载更多”按钮。加载失败时可在原位置重试。",
      "视频卡片的菜单提供稍后再看、播放队列、下载、分享与屏蔽等操作。"], settingsTab: 0),
    .init(id: "player", title: "播放与画质", location: "播放页 · 播放器下方控制栏", symbol: "play.rectangle", paragraphs: [
      "可切换分集、清晰度、倍速和音量。切换清晰度会保留播放位置与暂停状态；可选画质由视频、账号权限和设备决定。",
      "拖动进度条跳转，鼠标悬停时显示对应时间。有预览图的视频会显示缩略图；没有图片时保留时间提示。",
      "双击画面或按 ⌃⌘F 切换全屏，Esc 退出。播放详情显示编码、分辨率、下载速度、前向缓冲和连接状态。"]),
    .init(id: "keys", title: "播放快捷键", location: "播放器获得焦点时", symbol: "keyboard", paragraphs: [
      "空格暂停或继续。左右方向键单击跳转 5 秒。按住右方向键临时加速，松开后恢复原倍速；在线播放使用 2×，支持快速播放的本地视频使用 3×。",
      "⌘F 聚焦搜索框，⌘R 刷新当前列表或重试播放。输入文字时不会触发播放快捷键。",
      "“设置 → 播放与网络”可开启自动播放、记住观看位置和账号观看进度同步。"], settingsTab: 1),
    .init(id: "queue", title: "迷你播放器与播放队列", location: "右下角正在播放 · 播放页队列", symbol: "pip", paragraphs: [
      "播放中切换到其他页面，右下角会显示玻璃迷你播放器。可以暂停、继续或返回播放页，返回后保留当前进度。关闭迷你播放器会停止播放。",
      "播放页也可打开系统画中画。视频卡片可加入播放队列；队列支持切换条目、移除和清空，播放页可设置自动播放下一条或单曲循环。",
      "视频下方提供相关推荐、合集与分集入口，具体内容以视频返回的信息为准。"]),
    .init(id: "actions", title: "点赞、投币、收藏与分享", location: "播放页互动栏", symbol: "hand.thumbsup", paragraphs: [
      "单击点赞可点赞或取消。长按点赞 1.2 秒会显示进度动画并提交三连；提前松开取消长按。三连会执行点赞、投币和收藏，投币数量按视频允许的剩余数量决定。",
      "单独投币时可选 1 枚或 2 枚，并选择是否同时点赞。收藏可选择多个收藏夹，也可新建收藏夹。互动结果会更新到当前页面。",
      "分享支持复制视频链接、BV 号、二维码和系统分享，可附带播放位置。网络结果不确定时先刷新状态，避免重复投币。"]),
    .init(id: "comments", title: "评论与图片", location: "播放页评论区", symbol: "text.bubble", paragraphs: [
      "评论可按最热或最新排序，支持分页、楼中楼、回复、点赞以及删除自己的评论。表情按图片显示，加载失败时保留名称。",
      "点击评论图片可放大、缩放、切换和保存原图。较长评论可以展开，文字可以选择和复制。",
      "评论提交后以服务端返回结果为准。只收到提交回执、尚未拿到正文时，页面会提示等待确认。"]),
    .init(id: "danmaku", title: "弹幕显示与屏蔽", location: "播放页弹幕开关 · 设置 → 弹幕", symbol: "text.alignleft", paragraphs: [
      "可开关弹幕、发送弹幕及打开弹幕列表。设置提供透明度、区域、字号、滚动时长、重复合并与屏蔽规则。",
      "支持普通滚动、反向、顶部、底部、高级定位和 BAS 弹幕；旧式可执行代码弹幕不支持，复杂作品可能存在兼容差异。",
      "人物防挡默认关闭，开启后在本机识别人像，会增加处理开销。离线播放可读取随视频保存的弹幕；表情图片目前显示静态帧。"], settingsTab: 2),
    .init(id: "library", title: "观看记录与资料库", location: "左侧资料库菜单", symbol: "books.vertical", paragraphs: [
      "观看记录可切换账号历史和本机记录，重新打开视频可恢复各分集的位置。“设置 → 播放与网络”可关闭向账号同步新进度。",
      "收藏页可切换收藏夹、筛选视频和管理收藏内容。稍后再看用于保存待看的视频，可移除已不需要的条目。",
      "个人主页可查看投稿、动态和收藏，并管理关注关系。更多页面提供黑名单管理及创作中心、番剧、直播的官网入口。"]),
    .init(id: "messages", title: "消息与动态", location: "消息 · 关注动态 · 用户主页", symbol: "bubble.left.and.bubble.right", paragraphs: [
      "消息包括私信、回复我的、@ 我的、收到的赞和系统通知。私信可搜索会话、加载更多会话和历史消息，支持文字、图片和视频分享卡片。",
      "切换私信会话会保留各自的阅读位置。通知可打开相关内容，私信与评论共用表情渲染。",
      "动态支持查看文字、图片、视频及分享卡片，可发布和转发动态。用户主页可查看资料与关注关系；部分内容会跳转官网。"]),
    .init(id: "network", title: "分块加载与线程设置", location: "设置 → 播放与网络 → 视频加载", symbol: "network", paragraphs: [
      "“视频加载并发”控制同时读取视频分块的连接上限，范围 1–32。数据按播放顺序交给播放器；遇到超时会降低并发，网络恢复后逐步增加。这里的线程指网络连接，不是 CPU 核心数。",
      "Mac 与手机端共用分块加载。短分段按连接数拆成 64 KiB–1 MiB 的块；起播和切换画质时先传当前需要的数据，不等待完整缓存。修改并发后，在下次打开视频或切换画质时生效。",
      "“前向缓冲”控制播放器提前准备的时长。“持续预读到片尾”会把后续内容写入临时磁盘缓存，上限可设为 1–32 GB；切换视频或退出时清理。预读会增加网络流量，空间不足时继续按需播放。"], settingsTab: 1),
    .init(id: "downloads", title: "下载与缓存管理", location: "下载页 · 设置 → 缓存与下载", symbol: "arrow.down.circle", paragraphs: [
      "“缓存到应用”使用应用缓存目录；“下载到其他位置”可以选择文件夹。下载页可查看进度、暂停、继续、离线播放和管理完成记录。",
      "“设置 → 播放与网络”中的“每个下载的连接数”范围为 1–32，“同时下载任务”范围为 1–3。连接数作用于每个任务；同时增加两项会增加总连接数。暂停或退出后保留已接收的块，继续时校验媒体并补传。",
      "可选择同时保存弹幕。更改缓存目录只影响之后的下载，已有文件仍可管理。临时播放缓存与保存的离线视频分别管理；清理图片缓存不会删除视频。"], settingsTab: 3),
    .init(id: "appearance", title: "外观与帮助", location: "设置 → 外观与交互 / 关于", symbol: "paintpalette", paragraphs: [
      "可选择跟随系统、浅色或深色，以及通透或柔和的玻璃材质。自定义背景支持模糊和可见度调整，也可以恢复默认背景。",
      "可开关界面动画和列表自动加载。系统的减少动态效果与降低透明度设置也会影响显示。",
      "使用指南和更新说明会在首次安装或对应版本首次打开时展示一次。之后可从“帮助”菜单或“设置 → 关于”重新打开。"], settingsTab: 0)
  ]
  static let currentUpdates: [GuidePage] = [
    .init(id: "update-browse-navigation", title: "保留浏览位置与导航自定义", location: "1.1.3 · 2026-10-28", symbol: "sidebar.left", paragraphs: [
      "返回推荐、热门和分区时保留列表与浏览位置。设置中可选择返回推荐首页时自动刷新，默认关闭。",
      "导航项目支持显示、隐藏、排序与选择启动页。Mac 侧栏保留宽松间距；iPad 点击侧栏直接进入对应页面，首页标题常驻显示。"], settingsTab: 0),
    .init(id: "update-sequence-motion", title: "分 P、弹幕与界面动效", location: "1.1.3 · 2026-10-28", symbol: "play.rectangle", paragraphs: [
      "分 P 与合集分开展示，自动连播分别设置。弹幕输入移动到画面下方，选集使用圆角玻璃按钮。",
      "页面、设置和小窗统一使用非线性过渡，支持关闭动画及减少动态效果。移动端补载弹幕不再挤掉正在滚动的文字。",
      "移动版新增后台播放设置及系统播放控制；Duo 保留手机导航，iPad 使用分栏布局。长时锁屏与音频中断恢复仍在验证。"], settingsTab: 1),
    .init(id: "update-login", title: "登录恢复与移动版修复", location: "1.1.2 · 2026-10-25", symbol: "person.crop.circle", paragraphs: [
      "恢复本机登录后，不再复用恢复前的游客账号查询结果。iPhone 和 iPad 启动时会等待本机凭据读取完成，再检查登录。",
      "联网检查遇到断网或超时时保留本机登录并重试，只有服务端明确返回未登录才提示重新登录。",
      "同次更新的 iPad 版本修复消息分类图标裁切；iOS 自签安装包增加签名结构校验，仍需要使用自己的账号或证书签名安装。"]),
    .init(id: "update-playback", title: "播放失败与画质切换", location: "1.1.1 · 2026-10-25", symbol: "play.rectangle", paragraphs: [
      "修复部分媒体地址与分段信息格式导致的播放失败。一条备选流无效时继续检查其他可用流，并尝试有效的备用地址。",
      "切换画质时复用连接，起播阶段限制并发，出画后逐步恢复到设置上限。保留观看位置与暂停状态。",
      "仍然无法播放时，可在错误提示中复制脱敏诊断，连同设备、版本、BV 号和网络类型提交反馈。"]),
    .init(id: "update-codec", title: "首选编码", location: "设置 → 播放与网络", symbol: "cpu", paragraphs: [
      "Mac 增加自动、优先 AV1 和优先 HEVC 选项。没有所选编码时使用可用格式，设置在下次打开或切换画质时生效。",
      "设置中显示设备报告的硬件解码能力，实际解码方式由系统播放器选择。"], settingsTab: 1),
    .init(id: "update-inbox", title: "消息与回复", location: "1.1.1 · 2026-10-25", symbol: "bubble.left.and.bubble.right", paragraphs: [
      "Mac 与手机端显示私信、回复、@ 和收到的赞的未读数。前台定时同步，进入后台暂停。",
      "点赞消息说明被赞的是视频、评论或其他内容；Mac 回复改为独立输入窗口，可从通知定位对应评论。",
      "同次更新的 iPad 版本增加适应窗口宽度的侧栏、网格和播放页，收起播放页后可从小播放器返回。"])
  ]
  static let release102 = GuidePage(id: "release-1.0.2", title: "1.0.2", location: "版本记录", symbol: "clock.arrow.circlepath", paragraphs: [
    "原生 macOS 浏览与播放，提供推荐、热门、搜索、账号登录和资料库。支持画质切换、全屏、弹幕和视频下载。",
    "播放使用分块读取和临时磁盘预读；设置提供加载并发、下载并发、缓冲与缓存目录控制。"])
  static func updates(after previous: String?) -> [GuidePage] {
    currentUpdates + (previous == nil || previous!.compare("1.0.2", options: .numeric) == .orderedAscending ? [release102] : [])
  }
}

@MainActor final class FeatureGuideController: NSObject, NSWindowDelegate {
  let history: GuideHistory
  private(set) var window: NSWindow?
  private var presentationTask: Task<Void, Never>?
  weak var store: Store?
  init(history: GuideHistory? = nil) { self.history = history ?? GuideHistory() }
  func scheduleAutomaticPresentation() {
    guard let store, history.pending(hasSavedLogin: store.api.signedIn) != nil, presentationTask == nil else { return }
    presentationTask = Task { @MainActor [weak self] in
      for _ in 0..<40 {
        guard !Task.isCancelled else { return }
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain && $0.attachedSheet == nil }) { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      guard !Task.isCancelled, let self, let store = self.store else { return }
      self.presentationTask = nil
      guard !store.showLogin, self.window == nil,
        let mode = self.history.pending(hasSavedLogin: store.api.signedIn) else { return }
      if self.present(mode) { self.history.didPresent() }
    }
  }
  func show(_ mode: GuideHistory.Presentation) {
    presentationTask?.cancel(); presentationTask = nil
    _ = present(mode) // Manual replay does not consume the automatic receipt.
  }
  @discardableResult private func present(_ mode: GuideHistory.Presentation) -> Bool {
    guard let store else { return false }
    if window == nil {
      let created = NSWindow(contentRect: .init(x: 0, y: 0, width: 920, height: 680),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      created.isReleasedWhenClosed = false; created.isRestorable = false
      created.tabbingMode = .disallowed; created.minSize = .init(width: 800, height: 580)
      created.delegate = self; created.center(); window = created
    }
    window?.title = "Bilibili NEXT · " + (mode == .tutorial ? "使用指南" : "更新说明")
    window?.contentView = NSHostingView(rootView: FeatureGuideView(store: store, mode: mode, close: { [weak self] in self?.close() }))
    NSApp.activate(); window?.makeKeyAndOrderFront(nil)
    return window?.isVisible == true
  }
  func close() { window?.performClose(nil) }
  func windowWillClose(_ notification: Notification) {
    guard notification.object as? NSWindow === window else { return }
    window?.contentView = nil; window = nil
  }
}

struct FeatureGuideView: View {
  @Bindable var store: Store
  let mode: GuideHistory.Presentation
  let close: () -> Void
  @State private var tutorial = false
  @State private var selected = 0
  @Environment(\.openSettings) private var openSettings
  private var pages: [GuidePage] {
    if tutorial || mode == .tutorial { return GuideContent.tutorial }
    if case .update(let previous) = mode { return GuideContent.updates(after: previous) }
    return GuideContent.currentUpdates
  }
  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 16) {
        Label("Bilibili NEXT", systemImage: "play.rectangle.fill").font(.headline)
        Text(tutorial || mode == .tutorial ? "使用指南" : "更新说明").font(.title2.bold())
        Text("版本 \(GuideContent.version)").font(.caption).foregroundStyle(.secondary)
        ScrollView {
          VStack(spacing: 6) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
              Button { selected = index } label: {
                Label(page.title, systemImage: page.symbol).font(.callout)
                  .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                  .background(selected == index ? biliPink.opacity(0.13) : .clear, in: .rect(cornerRadius: 10))
                  .contentShape(.rect)
              }.buttonStyle(NavigationButtonStyle()).accessibilityAddTraits(selected == index ? .isSelected : [])
            }
          }
        }
        if mode != .tutorial {
          Button(tutorial ? "查看更新说明" : "查看完整使用指南") { selected = 0; tutorial.toggle() }
            .buttonStyle(.glass)
        }
      }.padding(20).frame(width: 246).background(.regularMaterial)
      VStack(alignment: .leading, spacing: 20) {
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            if let reason = store.loginUpgradeReason {
              VStack(alignment: .leading, spacing: 10) {
                Label("需要更新登录", systemImage: "person.crop.circle.badge.exclamationmark").font(.headline)
                Text(reason.message)
                Text("可以稍后处理。原登录会保留，扫码不会自动投币。").font(.callout).foregroundStyle(.secondary)
                Button("重新登录") { close(); store.login() }.buttonStyle(.glassProminent)
              }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(biliPink.opacity(0.08), in: .rect(cornerRadius: 16))
            }
            let page = pages[min(selected, pages.count - 1)]
            Image(systemName: page.symbol).font(.system(size: 32)).foregroundStyle(biliPink)
            VStack(alignment: .leading, spacing: 8) {
              Text(page.title).font(.largeTitle.bold())
              Text(page.location).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(page.paragraphs, id: \.self) { paragraph in
              Text(paragraph).font(.body).lineSpacing(6).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let tab = page.settingsTab {
              Button("打开相关设置") { store.preferencesTab = tab; openSettings() }.buttonStyle(.glass)
            }
          }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }.id("\(tutorial)-\(selected)")
        Divider()
        HStack {
          Text("\(selected + 1) / \(pages.count)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
          Spacer()
          Button("上一页") { selected -= 1 }.disabled(selected == 0)
          if selected + 1 < pages.count { Button("下一页") { selected += 1 }.buttonStyle(.glassProminent) }
          Button(selected + 1 == pages.count ? "完成" : "关闭") { close() }.keyboardShortcut(.cancelAction)
        }.buttonStyle(.glass)
      }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }.background(Color(nsColor: .windowBackgroundColor)).tint(biliPink).appAppearance()
  }
}
