import SwiftUI

extension API {
  func videoAid(_ video: Video) async throws -> Int {
    if let aid = video.aid, aid > 0 { return aid }
    return try await detail(video.bvid).aid
  }
  func removeWatchLater(_ video: Video) async throws {
    let aid = try await videoAid(video)
    _ = try await post("/x/v2/history/toview/del", ["aid": String(aid)])
  }
}
struct LibraryToolbar: View {
  @Bindable var store: Store
  @State private var managing = false
  var body: some View {
    HStack(spacing: 12) {
      TextField(store.destination == .favorites ? "搜索当前收藏夹" : "搜索稍后再看", text: $store.libraryQuery)
        .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
        .onSubmit { if store.destination == .favorites { store.reload() } }
      if store.destination == .favorites { Button("搜索") { store.reload() }.buttonStyle(.appGlassButton) }
      if !store.videos.isEmpty {
        Button { if let first = store.videos.first { store.openFeedVideo(first) } } label: { Label("播放列表", systemImage: "play.fill") }.buttonStyle(.appGlassButton)
      }
      Spacer()
      Button("管理") { managing = true }.buttonStyle(.appGlassButton)
    }.sheet(isPresented: $managing) { LibraryManager(store: store) }
  }
}
struct LibraryManager: View {
  @Bindable var store: Store
  @Environment(\.dismiss) private var dismiss
  @State private var selected: Set<String> = []
  @State private var target = 0
  @State private var busy = false
  @State private var error: String?
  @State private var notice: String?
  @State private var confirm = false
  @State private var folderEditor = false
  private var favorites: Bool { store.destination == .favorites }
  private var selectedVideos: [Video] { store.videos.filter { selected.contains($0.bvid) } }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack { Text(favorites ? "管理收藏" : "管理稍后再看").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.disabled(busy) }
      if favorites {
        HStack {
          Button("编辑收藏夹") { folderEditor = true }.disabled(store.selectedFolder == 0)
          Picker("目标收藏夹", selection: $target) { Text("选择收藏夹").tag(0); ForEach(store.folders.filter { $0.id != store.selectedFolder }) { Text($0.title).tag($0.id) } }
          Button("复制到") { run(.copy) }.disabled(target == 0 || selected.isEmpty)
          Button("移动到") { run(.move) }.disabled(target == 0 || selected.isEmpty)
        }.buttonStyle(.appGlassButton)
      }
      HStack {
        Button(selected.count == store.videos.count ? "取消全选" : "选择已加载视频") { selected = selected.count == store.videos.count ? [] : Set(store.videos.map(\.bvid)) }
        if !favorites { Button("选择已看完") { selected = Set(store.videos.filter { $0.progress == -1 || ($0.duration > 0 && ($0.progress ?? 0) >= $0.duration) }.map(\.bvid)) } }
        Spacer(); Text("已选 \(selected.count)").foregroundStyle(.secondary)
        Button("移除所选", role: .destructive) { confirm = true }.disabled(selected.isEmpty)
      }.buttonStyle(.appGlassButton)
      ScrollView { LazyVStack(spacing: 10) { ForEach(store.videos) { video in
        Toggle(isOn: Binding(get: { selected.contains(video.bvid) }, set: { if $0 { selected.insert(video.bvid) } else { selected.remove(video.bvid) } })) {
          HStack(spacing: 12) { Thumbnail(url: video.cover, mode: .fill).frame(width: 104, height: 59).clipShape(.rect(cornerRadius: 8)); VStack(alignment: .leading) { Text(video.title).lineLimit(2); Text(video.author).font(.caption).foregroundStyle(.secondary) }; Spacer() }
        }.toggleStyle(.checkbox).padding(10).appGlass(12)
      } } }
      if let error { Text(error).foregroundStyle(.red).font(.callout) }
      if let notice { Text(notice).foregroundStyle(.secondary).font(.callout) }
      if busy { ProgressView("正在处理所选视频") }
    }.padding(24).frame(width: 760, height: 620).background { GlassBackdrop() }.disabled(busy)
      .confirmationDialog("从\(favorites ? "当前收藏夹" : "稍后再看")移除 \(selected.count) 个视频？", isPresented: $confirm, titleVisibility: .visible) {
        Button("移除", role: .destructive) { run(.remove) }
      }
      .sheet(isPresented: $folderEditor) { FavoriteFolderEditor(store: store) }
  }
  private enum Operation { case copy, move, remove }
  private func run(_ operation: Operation) {
    guard !busy, !selectedVideos.isEmpty else { return }
    let videos = selectedVideos, folder = store.selectedFolder, target = target
    busy = true; error = nil; notice = nil
    Task {
      var completed = 0
      do {
        for video in videos {
          if favorites {
            let aid = try await store.api.videoAid(video)
            try await store.api.changeVideoFavorites(aid: aid, changes: FavoriteChanges(
              original: operation == .copy ? [] : [folder], selected: operation == .remove ? [] : [target]))
          } else { try await store.api.removeWatchLater(video) }
          completed += 1; selected.remove(video.bvid)
        }
        notice = "已处理 \(completed) 个视频"
      } catch { self.error = "已完成 \(completed)/\(videos.count)：" + error.localizedDescription }
      busy = false; store.folders = []; store.reload()
    }
  }
}
struct FavoriteFolderEditor: View {
  @Bindable var store: Store
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var intro = ""
  @State private var cover = ""
  @State private var isPrivate = false
  @State private var ready = false
  @State private var busy = false
  @State private var error: String?
  @State private var deleting = false
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("编辑收藏夹").font(.title2.bold())
      TextField("名称", text: $title).textFieldStyle(.roundedBorder)
      TextField("简介", text: $intro, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
      Toggle("私密收藏夹", isOn: $isPrivate)
      if let error { Text(error).foregroundStyle(.red) }
      if !ready && error == nil { ProgressView() }
      HStack {
        Button("删除收藏夹", role: .destructive) { deleting = true }.disabled(!ready || busy)
        Spacer(); Button("取消") { dismiss() }.disabled(busy)
        Button("保存") { save(deleting: false) }.disabled(!ready || busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 20)
      }.buttonStyle(.appGlassButton)
    }.padding(24).frame(width: 480).background { GlassBackdrop() }
      .task {
        do {
          let data = try await store.api.request("/x/v3/fav/folder/info", ["media_id": String(store.selectedFolder)])
          title = data["title"] as? String ?? ""; intro = data["intro"] as? String ?? ""; cover = data["cover"] as? String ?? ""; isPrivate = FavoriteFolder.privacyIsPrivate(data["attr"] as? Int ?? 0); ready = true
        } catch { self.error = error.localizedDescription }
      }
      .alert("删除这个收藏夹及其中的收藏记录？", isPresented: $deleting) { Button("删除", role: .destructive) { save(deleting: true) }; Button("取消", role: .cancel) {} } message: { Text("视频本身不会被删除，此操作无法撤销。") }
  }
  private func save(deleting: Bool) {
    busy = true; error = nil
    let folder = store.selectedFolder
    Task {
      do {
        if deleting { _ = try await store.api.post("/x/v3/fav/folder/del", ["media_ids": String(folder)]) }
        else { _ = try await store.api.post("/x/v3/fav/folder/edit", ["media_id": String(folder), "title": title.trimmingCharacters(in: .whitespacesAndNewlines), "intro": intro, "cover": cover, "privacy": isPrivate ? "1" : "0"]) }
        store.folders = []; if deleting { store.selectedFolder = 0 }; store.reload(); dismiss()
      } catch { self.error = error.localizedDescription }
      busy = false
    }
  }
}
