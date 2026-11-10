import SwiftUI

struct DownloadPage: View {
  @Bindable var store: Store
  @State private var filter = 0
  @State private var deleting: SavedDownload?
  private var visibleJobs: [DownloadJob] {
    store.downloads.jobs.filter { !$0.finished && (filter == 0 || ($0.cached ? filter == 1 : filter == 2)) }
  }
  private var visibleSaved: [SavedDownload] {
    store.downloads.saved.filter { filter == 0 || ($0.cached == true ? filter == 1 : filter == 2) }
  }
  var body: some View {
    ScrollView {
      GlassEffectContainer(spacing: 20) {
      LazyVStack(alignment: .leading, spacing: 20) {
        HStack {
          Text("下载").font(AppLayout.pageTitle)
          Spacer()
          SettingsLink { Label("下载设置", systemImage: "gearshape") }.buttonStyle(.glass)
        }
        Picker("显示", selection: $filter) {
          Text("全部").tag(0)
          Text("应用缓存").tag(1)
          Text("外部下载").tag(2)
        }.pickerStyle(.segmented).frame(width: 330)
        let bytes = store.downloads.saved.filter { $0.cached == true }.compactMap(\.byteCount)
          .reduce(0, +)
        HStack {
          Label(
            "应用缓存 " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
            systemImage: "internaldrive")
          Spacer()
          Button("打开缓存目录") {
            try? FileManager.default.createDirectory(
              at: AppPaths.cache, withIntermediateDirectories: true)
            NSWorkspace.shared.open(AppPaths.cache)
          }
        }.font(.callout).foregroundStyle(.secondary)
        if let message = store.downloads.message {
          HStack {
            Text(message)
            Spacer()
            Button {
              store.downloads.message = nil
            } label: {
              Image(systemName: "xmark")
            }.buttonStyle(.plain)
          }.padding(16).floatingGlass(AppLayout.panelRadius)
        }
        ForEach(
          visibleJobs, id: \.pendingRowID
        ) { job in
          HStack(spacing: 16) {
            Thumbnail(url: job.video.cover, mode: .fill).frame(width: 116, height: 72).clipShape(
              RoundedRectangle(cornerRadius: AppLayout.mediaRadius))
            VStack(alignment: .leading, spacing: 7) {
              Text(job.video.title).lineLimit(1)
              ProgressView(value: job.progress)
              HStack {
                Text(job.error ?? job.status)
                Spacer()
                Text("\(Int(job.progress*100))%").monospacedDigit()
              }.font(.caption).foregroundStyle(.secondary)
            }
            if job.cancelled || job.error != nil {
              Button("继续") { store.downloads.retry(job, api: store.api) }.buttonStyle(.glass)
            } else {
              Button {
                store.downloads.pause(job)
              } label: {
                Image(systemName: "pause.circle")
              }.help("暂停")
            }
            Menu {
              Button("移除任务") { store.downloads.removeJob(job) }
            } label: {
              Image(systemName: "ellipsis")
            }.menuStyle(.borderlessButton).frame(width: 22)
          }.padding(16).floatingGlass(AppLayout.panelRadius)
        }
        ForEach(
          visibleSaved, id: \.completedRowID
        ) { entry in
          HStack(spacing: 16) {
            Thumbnail(url: entry.video.cover, mode: .fill).frame(width: 116, height: 72).clipShape(
              RoundedRectangle(cornerRadius: AppLayout.mediaRadius))
            VStack(alignment: .leading, spacing: 7) {
              Text(entry.video.title).lineLimit(2)
              Text(
                entry.quality + " · " + (entry.cached == true ? "应用缓存" : "外部下载")
                  + (entry.danmakuPath == nil ? "" : " · 含弹幕")
              ).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if FileManager.default.fileExists(atPath: entry.path) {
              Button("播放") {
                store.openSaved(entry)
              }.buttonStyle(.glass)
              Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
              } label: {
                Image(systemName: "folder")
              }.help("在 Finder 中显示")
            } else {
              Text("文件已移动").font(.caption).foregroundStyle(.secondary)
            }
            Menu {
              Button("移除记录") { store.downloads.forget(entry) }
              if entry.cached == true { Button("移到废纸篓", role: .destructive) { deleting = entry } }
            } label: {
              Image(systemName: "ellipsis")
            }.menuStyle(.borderlessButton).frame(width: 22)
          }.padding(16).floatingGlass(AppLayout.panelRadius)
        }
        if visibleJobs.isEmpty && visibleSaved.isEmpty {
          ContentUnavailableView(
            "还没有下载", systemImage: "arrow.down.circle", description: Text("在播放页选择清晰度后缓存或下载"))
        }
      }.padding(AppLayout.pageInset).padding(.vertical, 8)
      }
    }
    .confirmationDialog(
      "将这条缓存移到废纸篓？",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button("移到废纸篓", role: .destructive) {
        if let deleting { store.downloads.deleteCache(deleting) }
        deleting = nil
      }
      Button("取消", role: .cancel) { deleting = nil }
    }
  }
}
