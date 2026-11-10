import SwiftUI

struct DanmakuFilteringControls: View {
  @AppStorage("danmakuScrolling") private var scrolling = true
  @AppStorage("danmakuTop") private var top = true
  @AppStorage("danmakuBottom") private var bottom = true
  @AppStorage("danmakuColored") private var colored = true
  @AppStorage("danmakuAvoidSubtitles") private var subtitles = true
  @AppStorage("danmakuDeduplicate") private var deduplicate = false
  @AppStorage("danmakuBlockedWords") private var blocked = ""
  @AppStorage("danmakuPersonAvoidance") private var personAvoidance = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      toggle("滚动弹幕", $scrolling)
      toggle("顶部弹幕", $top)
      toggle("底部弹幕", $bottom)
      toggle("彩色弹幕", $colored)
      Divider()
      toggle("保留底部字幕区域", $subtitles)
      #if os(macOS)
      toggle("人物防挡", $personAvoidance)
      #endif
      toggle("合并短时间内重复弹幕", $deduplicate)
      Text("屏蔽词 · 每行一个").font(.caption).foregroundStyle(.secondary)
      TextEditor(text: $blocked).font(.body).frame(height: 64)
        .scrollContentBackground(.hidden).padding(6).appGlass(10)
        .accessibilityLabel("弹幕屏蔽词")
      Text("应用于普通弹幕，高级弹幕保留作者布局。").font(.caption).foregroundStyle(.secondary)
    }.toggleStyle(.switch)
  }
  private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
    HStack {
      Text(title)
      Spacer(minLength: 12)
      Toggle(title, isOn: value).labelsHidden().fixedSize()
    }
  }
}

struct DanmakuSettingsButton: View {
  var onPresentationChange: ((Bool) -> Void)?
  var onShowList: (() -> Void)?
  @Environment(\.colorScheme) private var colorScheme
  @State private var showing = false
  @AppStorage("danmakuOpacity") private var opacity = 0.85
  @AppStorage("danmakuScale") private var scale = 1.0
  @AppStorage("danmakuArea") private var area = 0.5
  var body: some View {
    Button { showing.toggle() } label: { Image(systemName: "slider.horizontal.3") }
      .buttonStyle(.glass).help("弹幕设置").accessibilityLabel("弹幕设置")
      .popover(isPresented: $showing) {
        VStack(alignment: .leading, spacing: 14) {
          Text("弹幕设置").font(.headline)
          Grid(alignment: .leading, horizontalSpacing: 12) {
            GridRow { Text("不透明度"); Slider(value: $opacity, in: 0.1...1).accessibilityLabel("不透明度") }
            GridRow { Text("文字大小"); Slider(value: $scale, in: 0.5...2).accessibilityLabel("文字大小") }
            GridRow { Text("显示区域"); Slider(value: $area, in: 0.2...1).accessibilityLabel("显示区域") }
          }
          Divider()
          DanmakuFilteringControls()
          if let onShowList {
            Divider()
            Button("打开弹幕列表") { showing = false; onShowList() }
          }
        }.padding(20).frame(width: 330)
          .foregroundStyle(.primary)
          // Keep text contrast stable even over a bright video frame.
          .background(.background)
          // Fullscreen controls override the SwiftUI scheme. Apply it to the
          // presentation too, so AppKit's popover and its labels stay in sync.
          .preferredColorScheme(colorScheme)
      }
      .onChange(of: showing) { _, presented in onPresentationChange?(presented) }
  }
}
