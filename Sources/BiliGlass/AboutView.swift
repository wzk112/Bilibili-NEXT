import SwiftUI

struct ProjectCredit: Identifiable {
  var id: String { name }
  let name: String
  let url: String
  let purpose: String
  static let references: [Self] = [
    .init(name: "Bilibili-thread-ripper", url: "https://github.com/MrTangLuyao/Bilibili-thread-ripper", purpose: "分块续传、连接调度与 CDN 恢复思路"),
    .init(name: "PiliPlus", url: "https://github.com/bggRGjQaUbCoE/PiliPlus", purpose: "客户端扫码授权与投币协议"),
    .init(name: "biliuwp-lite", url: "https://github.com/xiaoyaocz/biliuwp-lite", purpose: "客户端投币与三连协议"),
    .init(name: "IINA", url: "https://github.com/iina/iina", purpose: "原生播放器架构"),
    .init(name: "IINA+", url: "https://github.com/xjbeta/iina-plus", purpose: "DASH 媒体模型"),
    .init(name: "bilibili-API-collect", url: "https://github.com/bilibili-plugins/bilibili-api-collect", purpose: "视频互动、收藏、评论和历史接口文档"),
    .init(name: "bilibili-API-collect（pskdje）", url: "https://github.com/pskdje/bilibili-API-collect", purpose: "私信、表情与观看进度接口文档"),
    .init(name: "BAS", url: "https://github.com/bilibili/bas", purpose: "BAS 弹幕语言规范"),
    .init(name: "DanmakuFlameMaster", url: "https://github.com/bilibili/DanmakuFlameMaster", purpose: "高级定位弹幕数据格式"),
    .init(name: "LyricsX Next", url: "https://github.com/wzk112/LyricsX-Next", purpose: "首次启动指南与版本介绍的展示逻辑")
  ]
}

struct AboutView: View {
  @Bindable var store: Store
  @State private var document: LicenseDocument?
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      card("Bilibili NEXT") {
        HStack { Text("版本"); Spacer(); Text(GuideContent.version).foregroundStyle(.secondary) }
        HStack { Text("系统"); Spacer(); Text("macOS 15 及以上").foregroundStyle(.secondary) }
        Link("项目地址 · wzk112/Bilibili-NEXT", destination: URL(string: "https://github.com/wzk112/Bilibili-NEXT")!)
        Link("反馈问题", destination: URL(string: "https://github.com/wzk112/Bilibili-NEXT/issues")!)
        HStack {
          Button("使用指南") { store.guide.show(.tutorial) }
          Button("更新说明") { store.guide.show(.update(previous: nil)) }
        }.buttonStyle(.appGlassButton)
        Button("完整更新日志") { document = .init(title: "更新日志", resource: "CHANGELOG", ext: "md") }.buttonStyle(.appGlassButton)
      }
      card("软件更新") { UpdateSettings() }
      card("用途与声明") {
        Text("本项目面向个人学习与研究，是非官方哔哩哔哩客户端，与哔哩哔哩官方无任何关联，未获得官方授权或背书。")
        Text("软件按现状提供，不作可用性或适用性保证。使用时请遵守适用法律和平台规则，尊重视频、图片、商标及其他内容权利人的权益。")
        Text("本项目源码采用 MIT 协议。个人学习与研究是项目定位，不构成对 MIT 授权范围的额外限制。第三方组件按各自许可证使用。")
        Button("查看本项目 MIT 协议") { document = .init(title: "Bilibili NEXT · MIT License", resource: "LICENSE", ext: "txt") }.buttonStyle(.appGlassButton)
      }
      card("使用的开源组件") {
        Link("BiliKit-Mac · shiinayane", destination: URL(string: "https://github.com/shiinayane/BiliKit-Mac")!).font(.headline)
        Text("MIT License · 使用 BiliModels、BiliApplication、BiliNetworking 和 BiliPlayback 模块，包含 DASH 播放桥接与网络基础组件。保留原作者版权声明。")
        Button("查看 BiliKit 的 MIT 协议") { document = .init(title: "BiliKit-Mac · MIT License", resource: "BiliKit-LICENSE", ext: "txt") }.buttonStyle(.appGlassButton)
      }
      card("软件更新组件") {
        Link("Sparkle 2.9.6", destination: URL(string: "https://github.com/sparkle-project/Sparkle")!).font(.headline)
        Text("BSD-2-Clause 及所附第三方许可；用于检查、验证和安装 macOS 更新。")
        Button("查看 Sparkle 许可") { document = .init(title: "Sparkle License", resource: "Sparkle-LICENSE", ext: "txt") }.buttonStyle(.appGlassButton)
      }
      card("参考项目与文档") {
        Text("以下项目用于协议、格式或设计参考；本项目独立实现对应 Swift 代码，未打包这些项目的实现。各项目的许可证见原仓库。")
          .font(.callout).foregroundStyle(.secondary)
        ForEach(ProjectCredit.references) { project in
          VStack(alignment: .leading, spacing: 4) {
            Link(project.name, destination: URL(string: project.url)!).font(.headline)
            Text(project.purpose).font(.callout).foregroundStyle(.secondary)
          }
        }
        Button("查看完整第三方说明") { document = .init(title: "第三方组件与参考说明", resource: "THIRD_PARTY", ext: "md") }.buttonStyle(.pointerGlass)
      }
    }.tint(.primary).sheet(item: $document) { item in
      VStack(alignment: .leading, spacing: 16) {
        HStack { Text(item.title).font(.title2.bold()); Spacer(); Button("关闭") { document = nil }.keyboardShortcut(.cancelAction) }
        ScrollView {
          Text(item.contents).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
      }.padding(24).frame(minWidth: 680, idealWidth: 760, minHeight: 500, idealHeight: 600)
    }
  }
  private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title).font(.headline)
      content()
    }.padding(22).frame(maxWidth: .infinity, alignment: .leading).floatingGlass(AppLayout.panelRadius)
  }
}

struct LicenseDocument: Identifiable {
  var id: String { resource }
  let title: String
  let resource: String
  let ext: String
  var contents: String {
    guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
      let value = try? String(contentsOf: url, encoding: .utf8) else {
      return "未找到本地说明文件。请在项目仓库查看 LICENSE 与 THIRD_PARTY.md。"
    }
    return value
  }
}
