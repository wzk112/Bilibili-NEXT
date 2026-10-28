import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum AppPaths {
  static var support: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("BiliGlass")
  }
  static var cache: URL {
    if let path = UserDefaults.standard.string(forKey: "cacheDirectory"), !path.isEmpty {
      return URL(fileURLWithPath: path)
    }
    return support.appendingPathComponent("MediaCache")
  }
  static var transfers: URL { support.appendingPathComponent("Transfers") }
}
struct PreferencesView: View {
  @Bindable var store: Store
  @AppStorage("appearance") private var appearance = "dark"
  @AppStorage("glassStyle") private var glassStyle = "clear"
  @AppStorage("backgroundImage") private var backgroundImage = ""
  @AppStorage("backgroundBlur") private var backgroundBlur = false
  @AppStorage("backgroundOpacity") private var backgroundOpacity = 0.7
  @AppStorage("interfaceAnimations") private var animations = true
  @AppStorage("autoLoadMore") private var autoLoadMore = true
  @AppStorage("rememberPosition") private var rememberPosition = true
  @AppStorage("syncWatchHistory") private var syncWatchHistory = true
  @AppStorage("autoPlay") private var autoPlay = true
  @AppStorage("autoPlayParts") private var autoParts = true
  @AppStorage("autoPlayNext") private var autoNext = false
  @AppStorage("videoCodecPreference") private var codec = "auto"
  @AppStorage("commentSort") private var commentSort = 1
  @State private var backgroundError: String?
  @State private var importing = false
  @AppStorage("downloadDanmaku") private var downloadDanmaku = true
  @AppStorage("downloadThreads") private var downloadThreads = 4
  @AppStorage("videoThreads") private var videoThreads = 4
  @AppStorage("simultaneousDownloads") private var simultaneousDownloads = 1
  @AppStorage("continuousPreload") private var continuousPreload = true
  @AppStorage("preloadDiskGB") private var preloadDiskGB = 8
  @AppStorage("bufferSeconds") private var bufferSeconds = 15.0
  @AppStorage("danmakuOpacity") private var opacity = 0.85
  @AppStorage("danmakuArea") private var area = 0.5
  @AppStorage("danmakuScale") private var scale = 1.0
  @AppStorage("danmakuDuration") private var duration = 8.0
  @AppStorage("cacheDirectory") private var cacheDirectory = ""
  @State private var cleared = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let categories = [("外观与交互", "paintpalette"), ("播放与网络", "play.rectangle"), ("弹幕", "text.bubble"), ("缓存与下载", "arrow.down.circle"), ("关于", "info.circle")]
  var body: some View {
    ZStack {
      GlassBackdrop()
      HStack(alignment: .top, spacing: 20) {
        VStack(alignment: .leading, spacing: 20) {
          Label("设置", systemImage: "slider.horizontal.3").font(.title2.weight(.semibold)).padding(.horizontal, 10)
          GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
              ForEach(categories.indices, id: \.self) { index in
                Button { store.preferencesTab = index } label: {
                  Label(categories[index].0, systemImage: categories[index].1)
                    .font(.body.weight(store.preferencesTab == index ? .semibold : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(.rect(cornerRadius: 14))
                }.buttonStyle(NavigationButtonStyle()).tint(.primary)
                  .appGlass(14, tint: store.preferencesTab == index ? biliPink.opacity(0.2) : .clear)
              }
            }
          }
          Spacer()
          Text("Bilibili NEXT").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 10)
        }.padding(14).frame(width: 200).frame(maxHeight: .infinity).floatingGlass(AppLayout.panelRadius)
        VStack(alignment: .leading, spacing: 16) {
          Text(categories[store.preferencesTab].0).font(.title2.weight(.semibold)).padding(.horizontal, 6).padding(.top, 4)
          ZStack(alignment: .top) {
            ScrollView {
              GlassEffectContainer(spacing: 16) {
              VStack(alignment: .leading, spacing: 16) {
                switch store.preferencesTab {
                case 0: appearanceSettings
                case 1: playbackSettings
                case 2: danmakuSettings
                case 3: cacheSettings
                default: aboutSettings
                }
                }.padding(AppLayout.pageInset)
              }
            }.scrollIndicators(.hidden)
              .id(store.preferencesTab).interfaceTransition()
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 24)).interfaceAnimation(store.preferencesTab)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.padding(24)
    }.frame(minWidth: 940, idealWidth: 980, minHeight: 700, idealHeight: 740).appAppearance().tint(biliPink)
  }
  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 18) {
      Text(title).font(.headline)
      content()
    }.padding(22).frame(maxWidth: .infinity, alignment: .leading).floatingGlass(24)
  }
  private var playbackSettings: some View {
    VStack(spacing: 18) {
      section("播放") {
        Picker("首选编码", selection: $codec) {
          ForEach(VideoCodecPreference.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Text("同一画质优先使用所选编码；没有对应流或播放失败时自动回退。下次打开视频或切换画质生效。")
          .font(.caption).foregroundStyle(.secondary)
        Text(VideoCodecPreference.hardwareDecodeSummary + "具体解码方式由系统播放器选择。")
          .font(.caption).foregroundStyle(.secondary)
        toggleRow("打开视频后自动播放", value: $autoPlay)
        toggleRow("分 P 自动连播", value: $autoParts)
        toggleRow("合集与播放列表自动连播", value: $autoNext)
        toggleRow("记住观看位置", value: $rememberPosition)
        toggleRow("同步观看进度到账号", value: $syncWatchHistory)
        Text("登录后同步新观看的视频；关闭后仅保存在本机。历史页始终保留本机记录入口。")
          .font(.caption).foregroundStyle(.secondary)
        sliderRow("前向缓冲", value:$bufferSeconds, range:5...120, step:5, display:"\(Int(bufferSeconds)) 秒")
        HStack { Text("HDR 显示"); Spacer(); Text(AVPlayer.eligibleForHDRPlayback ? "系统可用" : "系统当前不可用").foregroundStyle(.secondary) }
        Text("清晰度以视频、账号权限和设备支持为准。").font(.caption).foregroundStyle(.secondary)
      }
      section("视频加载") {
        toggleRow("持续预读到片尾", value: $continuousPreload)
        stepperRow("临时缓存上限（GB）", value: $preloadDiskGB, range: 1...32)
        Text("播放请求优先，后台继续预读并写入独立临时目录。切换视频或退出后清理；空间不足时改用按需播放。下次打开视频生效。")
          .font(.caption).foregroundStyle(.secondary)
        HStack { Text("播放线路"); Spacer(); Text("自动择优").foregroundStyle(.secondary) }
        Text("起播时自动试读视频和音频线路，持续缓冲时重新选择。按当前网络响应选取。")
          .font(.caption).foregroundStyle(.secondary)
        stepperRow("视频加载并发", value:$videoThreads, range:1...32)
        Text("此值为并发上限。起播及切换画质先使用最多 4 路，出画后按传输情况逐步增加；切换视频或清晰度后生效。").font(.caption).foregroundStyle(.secondary)
      }
      section("下载") {
        stepperRow("每个下载的连接数", value:$downloadThreads, range:1...32)
        stepperRow("同时下载任务", value:$simultaneousDownloads, range:1...3)
      }
      section("键盘控制") {
        settingLine("空格", "暂停 / 继续")
        settingLine("← / →", "快退 / 快进 5 秒")
        settingLine("按住 →", "在线 2× / 本地 3×，松开恢复")
        settingLine("⌃⌘F / Esc", "进入 / 退出全屏")
        Text("输入文字时不触发播放快捷键。").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private var appearanceSettings: some View {
    VStack(spacing: 18) {
      section("首页与导航") { BrowsePreferenceFields() }
      section("外观") {
        Picker("颜色模式", selection: $appearance) {
          Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
        }.pickerStyle(.segmented)
        Picker("玻璃材质", selection: $glassStyle) {
          Text("通透").tag("clear"); Text("柔和").tag("regular")
        }.pickerStyle(.segmented)
        toggleRow("界面动画", value: $animations)
        Text("通透突出背景，柔和便于阅读。").font(.caption).foregroundStyle(.secondary)
      }
      section("背景") {
        HStack(spacing: 14) {
          Image(systemName: backgroundImage.isEmpty ? "circle.lefthalf.filled" : "photo").font(.title2).foregroundStyle(biliPink)
          VStack(alignment: .leading, spacing: 4) {
            Text(backgroundImage.isEmpty ? "默认渐变" : "自定义图片").font(.headline)
            Text("图片保存在应用中，原图保持不变。").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button(importing ? "正在处理…" : "选择图片…", action: chooseBackground).disabled(importing)
          if !backgroundImage.isEmpty { Button("恢复默认") { backgroundImage = "" } }
        }.buttonStyle(.glass).tint(.primary)
        toggleRow("模糊背景图片", value: $backgroundBlur).disabled(backgroundImage.isEmpty)
        sliderRow("背景可见度", value: $backgroundOpacity, range: 0.2...1, step: 0.05, display: "\(Int(backgroundOpacity * 100))%")
          .disabled(backgroundImage.isEmpty)
        if let backgroundError { Text(backgroundError).font(.caption).foregroundStyle(.red) }
      }
      section("浏览") {
        toggleRow("向下滚动自动加载", value: $autoLoadMore)
        Picker("默认评论排序", selection: $commentSort) { Text("最热").tag(1); Text("最新").tag(0) }.pickerStyle(.segmented)
        Text("适用于视频列表和评论。关闭自动加载后仍可点击加载更多。").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private func toggleRow(_ title: String, value: Binding<Bool>) -> some View {
    HStack { Text(title); Spacer(); Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).fixedSize() }
  }
  private func settingLine(_ title: String, _ value: String) -> some View {
    HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
  }
  private func chooseBackground() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    importing = true; backgroundError = nil
    Task {
      defer { importing = false }
      do { backgroundImage = try await BackgroundImages.shared.importImage(url).path }
      catch { backgroundError = error.localizedDescription }
    }
  }
  private var danmakuSettings: some View {
    section("显示") {
      Text("这是一条弹幕").font(.system(size: 25 * scale, weight: .semibold))
        .foregroundStyle(.white.opacity(opacity)).shadow(color: .black.opacity(0.8), radius: 1, y: 1)
        .frame(maxWidth: .infinity).frame(height: 70).appGlass(16)
      sliderRow("不透明度", value:$opacity, range:0.1...1, step:0.01, display:"\(Int(opacity*100))%")
      sliderRow("显示区域", value:$area, range:0.2...1, step:0.1, display:"\(Int(area*100))%")
      sliderRow("文字大小", value:$scale, range:0.5...2, step:0.1, display:"\(scale.formatted(.number.precision(.fractionLength(1))))×")
      sliderRow("滚动时长", value:$duration, range:3...15, step:1, display:"\(Int(duration)) 秒")
      Text("立即应用。高级弹幕保留作者布局；刷新率跟随屏幕。").font(.caption).foregroundStyle(.secondary)
      Divider()
      DanmakuFilteringControls()
    }
  }
  private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String) -> some View {
    HStack(spacing:14) {
      Text(title)
      Spacer(minLength:20)
      Slider(value:value,in:range,step:step).labelsHidden().accessibilityLabel(title).frame(minWidth:140, idealWidth:220, maxWidth:260)
      Text(display).monospacedDigit().frame(width:64,alignment:.trailing)
    }.accessibilityElement(children:.contain)
  }
  private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
    HStack(spacing:14) {
      Text(title)
      Spacer(minLength:20)
      Text("\(value.wrappedValue)").monospacedDigit().frame(width:36,alignment:.trailing)
      Stepper(title,value:value,in:range).labelsHidden().accessibilityLabel(title).fixedSize()
    }.accessibilityElement(children:.contain)
  }
  private var cacheSettings: some View {
    VStack(spacing: 18) {
      section("视频缓存") {
        HStack {
          Text("下载视频时同时保存弹幕"); Spacer()
          Toggle("下载视频时同时保存弹幕", isOn:$downloadDanmaku).labelsHidden().toggleStyle(.switch).fixedSize()
        }
        Text(AppPaths.cache.path).font(.callout).textSelection(.enabled).lineLimit(3)
        HStack {
          Button("更改目录…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            if panel.runModal() == .OK, let url = panel.url { cacheDirectory = url.path }
          }
          Button("在 Finder 中打开") {
            try? FileManager.default.createDirectory(
              at: AppPaths.cache, withIntermediateDirectories: true)
            NSWorkspace.shared.open(AppPaths.cache)
          }
        }.buttonStyle(.glass).tint(.primary)
        Text("修改目录后，新缓存保存到新位置，已有缓存仍可在下载页管理。").font(.caption).foregroundStyle(.secondary)
      }
      section("图片缓存") {
        Button(cleared ? "已清理" : "清理图片缓存") {
          Task {
            await ThumbnailCache.shared.clear()
            cleared = true
          }
        }.buttonStyle(.glass).tint(.primary)
        Text("解码图片缓存上限 32 MB，按显示尺寸加载；原图仅使用 128 MB 磁盘缓存。正在显示的图片另占内存。").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private var aboutSettings: some View { AboutView(store: store) }
}
