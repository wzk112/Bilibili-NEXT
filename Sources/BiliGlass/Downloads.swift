import AVFoundation
import BiliModels
import BiliNetworking
import CryptoKit
import SwiftUI

struct SavedDownload: Identifiable, Codable {
  var completedRowID: String { "saved-\(id)" }
  var id: UUID
  var video: Video
  var cid: Int
  var quality: String
  var path: String
  var date: Date
  var cached: Bool? = nil
  var danmakuPath: String? = nil
  var byteCount: Int64? = nil
}
struct PendingDownload: Codable {
  let id: UUID
  let video: Video
  let cid: Int
  let qn: Int
  let folder: String
  let cached: Bool
  let progress: Double
}
struct DownloadIndex: Codable {
  var saved: [SavedDownload]
  var jobs: [PendingDownload]
  /// iOS can move its data container during an update. Cached files live under
  /// the current app cache; exported files retain their explicit destination.
  func relocatingCache(to directory: URL) -> Self {
    Self(saved: saved.map { entry in
      guard entry.cached == true else { return entry }
      var copy = entry
      copy.path = directory.appendingPathComponent(URL(fileURLWithPath: entry.path).lastPathComponent).path
      copy.danmakuPath = entry.danmakuPath.map {
        directory.appendingPathComponent(URL(fileURLWithPath: $0).lastPathComponent).path
      }
      return copy
    }, jobs: jobs.map { job in
      PendingDownload(id: job.id, video: job.video, cid: job.cid, qn: job.qn,
        folder: job.cached ? directory.path : job.folder, cached: job.cached, progress: job.progress)
    })
  }
}
@MainActor @Observable final class DownloadJob: Identifiable {
  var pendingRowID: String { "pending-\(id)" }
  let id: UUID
  let video: Video
  let cid: Int
  let qn: Int
  let folder: URL
  let cached: Bool
  var progress = 0.0
  var status = "排队中"
  var error: String?
  var finished = false
  var cancelled = false
  var runID = UUID()
  var task: Task<Void, Never>?
  init(video: Video, cid: Int, qn: Int, folder: URL, cached: Bool = false, id: UUID = UUID()) {
    self.video = video
    self.cid = cid
    self.qn = qn
    self.folder = folder
    self.cached = cached
    self.id = id
  }
  func cancel() {
    cancelled = true
    task?.cancel()
    status = "已暂停"
  }
}
final class DownloadProgress: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int: Double] = [:]
  private var lastPublished = Date.distantPast
  let count: Int
  init(count: Int) { self.count = count }
  func set(_ index: Int, _ value: Double) -> Double? {
    lock.lock()
    defer { lock.unlock() }
    values[index] = value
    let total = values.values.reduce(0, +) / Double(max(1, count))
    let now = Date()
    guard total >= 1 || now.timeIntervalSince(lastPublished) >= 0.1 else { return nil }
    lastPublished = now
    return total
  }
}
enum ParallelMediaDownload {
  static let chunkSize: Int64 = 4 * 1024 * 1024
  static func ranges(length: Int64) -> [HTTPByteRange] {
    guard length > 0 else { return [] }
    var result: [HTTPByteRange] = []
    var start: Int64 = 0
    while start < length {
      let count = min(chunkSize, length - start)
      if let range = try? HTTPByteRange(start: start, endInclusive: start + count - 1) {
        result.append(range)
      }
      start += count
    }
    return result
  }
  static func fetch(
    _ representation: MediaRepresentation, directory: URL, threads: Int,
    update: @escaping @Sendable (Double) -> Void
  ) async throws -> URL {
    let transport = CDNTransport()
    let route = try await transport.select(representation, headers: API.mediaHeaders)
    let source = route.representation.primaryURL
    let r = representation.segmentBase.index
    let probe = try await HTTPRangeClient(streamer: transport).fetch(
      from: [source], range: HTTPByteRange(start: 0, endInclusive: r.endInclusive), headers: API.mediaHeaders)
    guard let length = probe.contentRange.completeLength, length > 0 else {
      throw BiliError(text: "无法确认媒体长度")
    }
    // A job has its own directory. Match the immutable media index and complete
    // length, not the CDN host or expiring URL, when resuming its verified parts.
    let identity = Data("v2|\(length)|\(representation.codecs)".utf8) + probe.body
    let hash = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    let marker = directory.appendingPathComponent("identity")
    if (try? String(contentsOf: marker, encoding: .utf8)) != hash {
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try hash.write(to: marker, atomically: true, encoding: .utf8)
    let ranges = ranges(length: length)
    let progress = DownloadProgress(count: ranges.count)
    let output = directory.appendingPathComponent("complete.mp4")
    if let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) as? NSNumber,
      size.int64Value == length { update(1); return output }
    let limit = max(1, min(32, threads))
    try await withThrowingTaskGroup(of: Void.self) { group in
      var next = 0
      func add(_ index: Int) {
        group.addTask {
          let range = ranges[index]
          let target = directory.appendingPathComponent("\(index).part")
          if let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size]) as? NSNumber,
            size.uint64Value == range.length {
            if let value = progress.set(index, 1) { update(value) }
            return
          }
          try await DownloadPiece.fetch(source, range: range, total: length, target: target,
            transport: transport) { p in
              if let value = progress.set(index, p) { update(value) }
            }
        }
      }
      for _ in 0..<min(limit, ranges.count) { add(next); next += 1 }
      while try await group.next() != nil {
        if next < ranges.count { add(next); next += 1 }
      }
    }
    try Task.checkCancellation()
    try await downloadIO {
      let partial = directory.appendingPathComponent("assembled.partial")
      try? FileManager.default.removeItem(at: partial)
      FileManager.default.createFile(atPath: partial.path, contents: nil)
      let writer = try FileHandle(forWritingTo: partial)
      defer { try? writer.close() }
      for index in ranges.indices {
        let reader = try FileHandle(forReadingFrom: directory.appendingPathComponent("\(index).part"))
        defer { try? reader.close() }
        while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty {
          try Task.checkCancellation()
          try writer.write(contentsOf: data)
        }
      }
      try writer.synchronize()
      try Task.checkCancellation()
      try? FileManager.default.removeItem(at: output)
      try FileManager.default.moveItem(at: partial, to: output)
    }
    update(1)
    return output
  }

}
@MainActor @Observable final class Downloads {
  var jobs: [DownloadJob] = []
  var activeCount: Int { jobs.filter { !$0.finished && !$0.cancelled && $0.error == nil }.count }
  var saved: [SavedDownload] = []
  var message: String?
  private let directory: URL
  private let index: URL
  private var lastSave = Date.distantPast
  init(storageDirectory: URL? = nil) {
    directory = storageDirectory ?? AppPaths.support
    index = directory.appendingPathComponent("downloads.json")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: index) {
      if var state = try? JSONDecoder().decode(DownloadIndex.self, from: data) {
        #if os(iOS)
        state = state.relocatingCache(to: directory.appendingPathComponent("MediaCache"))
        #endif
        saved = state.saved
        jobs = state.jobs.map { r in
          let j = DownloadJob(
            video: r.video, cid: r.cid, qn: r.qn, folder: URL(fileURLWithPath: r.folder),
            cached: r.cached, id: r.id)
          j.cancelled = true
          j.status = "已暂停"
          j.progress = r.progress
          return j
        }
      } else {
        saved = (try? JSONDecoder().decode([SavedDownload].self, from: data)) ?? []
        #if os(iOS)
        saved = DownloadIndex(saved: saved, jobs: []).relocatingCache(
          to: directory.appendingPathComponent("MediaCache")).saved
        #endif
      }
    }
  }
  @discardableResult func persist() -> Bool {
    let state = DownloadIndex(
      saved: saved,
      jobs: jobs.filter { !$0.finished }.map {
        PendingDownload(
          id: $0.id, video: $0.video, cid: $0.cid, qn: $0.qn, folder: $0.folder.path,
          cached: $0.cached, progress: $0.progress)
      })
    do { try JSONEncoder().encode(state).write(to: index, options: .atomic) } catch {
      message = "无法保存任务记录"
      return false
    }
    lastSave = Date()
    return true
  }
  func enqueue(video: Video, cid: Int, qn: Int, api: API, cached: Bool = false) {
    var folder = AppPaths.cache
    if !cached {
      #if os(macOS)
      let p = NSOpenPanel()
      p.canChooseDirectories = true
      p.canChooseFiles = false
      p.canCreateDirectories = true
      p.prompt = "保存到这里"
      guard p.runModal() == .OK, let url = p.url else { return }
      folder = url
      #else
      message = "请先缓存到应用，再从下载页面导出文件"
      return
      #endif
    }
    if jobs.contains(where: {
      $0.video.bvid == video.bvid && $0.cid == cid && $0.qn == qn && !$0.finished && !$0.cancelled
        && $0.error == nil
    }) {
      message = "已有相同任务"
      return
    }
    let job = DownloadJob(video: video, cid: cid, qn: qn, folder: folder, cached: cached)
    jobs.insert(job, at: 0)
    persist()
    job.task = Task { await run(job, api: api) }
  }
  func pause(_ job: DownloadJob) {
    job.cancel()
    persist()
  }
  func retry(_ job: DownloadJob, api: API) {
    let previous = job.task
    previous?.cancel()
    job.task = Task {
      await previous?.value
      guard !Task.isCancelled, jobs.contains(where: { $0 === job }), !job.finished else { return }
      job.cancelled = false
      job.error = nil
      job.status = "排队中"
      persist()
      await run(job, api: api)
    }
  }
  func removeJob(_ job: DownloadJob) {
    job.cancel()
    jobs.removeAll { $0.id == job.id }
    persist()
    Task {
      await job.task?.value
      try? FileManager.default.removeItem(
        at: directory.appendingPathComponent("Transfers/\(job.id)"))
    }
  }
  func run(_ job: DownloadJob, api: API) async {
    let temp = directory.appendingPathComponent("Transfers/\(job.id)")
    let token = UUID()
    job.runID = token
    do {
      try Task.checkCancellation()
      guard jobs.contains(where: { $0 === job }), !job.cancelled, !job.finished else { return }
      let limit = max(
        1, min(3, UserDefaults.standard.object(forKey: "simultaneousDownloads") as? Int ?? 1))
      while jobs.filter({
        $0.id != job.id && !$0.finished && !$0.cancelled && $0.error == nil && $0.status != "排队中"
      }).count >= limit {
        try await Task.sleep(for: .milliseconds(250))
        try Task.checkCancellation()
      }
      try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: job.folder, withIntermediateDirectories: true)
      let output = temp.appendingPathComponent("complete.mp4")
      let name = "\(safeFilename(job.video.title))_\(job.video.bvid)_\(job.cid)_\(job.qn)_\(job.id.uuidString.prefix(6))"
      let requested = job.folder.appendingPathComponent(name + ".mp4")
      var prepared = try await downloadIO { try DownloadPublication.restore(output) }
      // Recover pre-checkpoint releases only when the published MP4 and the validated
      // mux output match, ignoring export timestamps but comparing all media bytes.
      if prepared == nil, FileManager.default.fileExists(atPath: requested.path),
        FileManager.default.fileExists(atPath: output.path) {
        let matches = try await downloadIO {
          (try? DownloadPublication.digest(requested)) == (try DownloadPublication.digest(output))
        }
        if matches {
          try await Self.validateMedia(output)
          let quality = Self.qualityName(job.qn)
          prepared = try await downloadIO { try DownloadPublication.prepare(output, quality: quality) }
        }
      }
      if let prepared {
        try await finish(job, api: api, output: output, requested: requested, prepared: prepared, temp: temp)
        return
      }
      job.status = "获取清晰度"
      persist()
      let streams = try await api.streams(bvid: job.video.bvid, cid: job.cid)
      try Task.checkCancellation()
      guard let video = API.bestVideo(streams.videos, quality: job.qn) else {
        throw BiliError(text: "此清晰度已不可用")
      }
      let threads = max(
        1, min(32, UserDefaults.standard.object(forKey: "downloadThreads") as? Int ?? 4))
      job.status = "下载视频 · \(threads) 连接"
      persist()
      let v = try await ParallelMediaDownload.fetch(
        video, directory: temp.appendingPathComponent("video"), threads: threads
      ) { p in
        Task { @MainActor in
          guard job.runID == token, !job.cancelled, !job.finished, job.error == nil else { return }
          job.progress = max(job.progress, p * 0.8)
          if Date().timeIntervalSince(self.lastSave) > 1 { self.persist() }
        }
      }
      try Task.checkCancellation()
      job.status = "下载音频"
      persist()
      let a = try await ParallelMediaDownload.fetch(
        streams.audio, directory: temp.appendingPathComponent("audio"), threads: threads
      ) { p in
        Task { @MainActor in
          guard job.runID == token, !job.cancelled, !job.finished, job.error == nil else { return }
          job.progress = max(job.progress, 0.8 + p * 0.15)
        }
      }
      try Task.checkCancellation()
      job.status = "合并音视频"
      persist()
      try? FileManager.default.removeItem(at: output)
      try await Self.mux(video: v, audio: a, output: output)
      try Task.checkCancellation()
      let quality = streams.names[job.qn] ?? Self.qualityName(job.qn)
      let checkpoint = try await downloadIO { try DownloadPublication.prepare(output, quality: quality) }
      try await finish(job, api: api, output: output, requested: requested, prepared: checkpoint, temp: temp)
    } catch {
      if job.cancelled || Task.isCancelled {
        job.cancelled = true
        job.status = "已暂停"
      } else {
        job.error = error.localizedDescription
        job.status = "下载失败"
      }
      persist()
    }
  }
  private func finish(_ job: DownloadJob, api: API, output: URL, requested: URL,
                      prepared: PreparedDownload, temp: URL) async throws {
    job.status = "保存视频"; job.progress = max(job.progress, 0.95); persist()
    let target = try await downloadIO { try DownloadPublication.publish(output, to: requested, prepared: prepared) }
    try Task.checkCancellation()
    var sidecar: String?
    if UserDefaults.standard.object(forKey: "downloadDanmaku") as? Bool ?? true {
      job.status = "保存弹幕"; job.progress = 0.97; persist()
      do {
        let items = try await DanmakuController.all(cid: job.cid, duration: job.video.duration, api: api)
        try Task.checkCancellation()
        let url = target.deletingPathExtension().appendingPathExtension("danmaku.json")
        try await downloadIO {
          try JSONEncoder().encode(items).write(to: url, options: .atomic)
          try DanmakuController.xml(items, cid: job.cid).write(
            to: target.deletingPathExtension().appendingPathExtension("xml"), atomically: true, encoding: .utf8)
        }
        sidecar = url.path
      } catch {
        try Task.checkCancellation()
        message = "视频已保存，弹幕下载失败，可单独重试"
      }
    }
    try Task.checkCancellation()
    let previous = saved
    saved.removeAll { $0.id == job.id }
    saved.insert(SavedDownload(id: job.id, video: job.video, cid: job.cid, quality: prepared.quality,
      path: target.path, date: Date(), cached: job.cached, danmakuPath: sidecar,
      byteCount: prepared.byteCount), at: 0)
    job.finished = true; job.progress = 1; job.status = "已完成"
    guard persist() else {
      saved = previous; job.finished = false
      throw BiliError(text: "视频已保存，任务记录保存失败，请重试")
    }
    // Remove transient parts only after the completed index is safely on disk.
    try? FileManager.default.removeItem(at: temp)
  }
  private static func qualityName(_ qn: Int) -> String {
    [16:"360P 流畅", 32:"480P 清晰", 64:"720P 高清", 74:"720P 60帧", 80:"1080P 高清",
     112:"1080P 高码率", 116:"1080P 60帧", 120:"4K", 125:"HDR", 126:"杜比视界", 127:"8K"][qn] ?? "\(qn)"
  }
  static func validateMedia(_ url: URL) async throws {
    let result = AVURLAsset(url: url)
    let duration = try await result.load(.duration).seconds
    guard duration.isFinite, duration > 0,
      try await result.loadTracks(withMediaType: .video).count == 1,
      try await result.loadTracks(withMediaType: .audio).count == 1
    else { throw BiliError(text: "合并校验失败") }
  }
  #if os(macOS)
  func saveDanmaku(video: Video, cid: Int, api: API) async {
    let p = NSSavePanel()
    p.nameFieldStringValue = safeFilename(video.title) + ".xml"
    guard p.runModal() == .OK, let url = p.url else { return }
    message = "正在下载弹幕"
    do {
      let items = try await DanmakuController.all(cid: cid, duration: video.duration, api: api)
      try DanmakuController.xml(items, cid: cid).write(to: url, atomically: true, encoding: .utf8)
      message = "已保存 \(items.count) 条弹幕"
    } catch { message = error.localizedDescription }
  }
  #endif
  @discardableResult func forget(_ entry: SavedDownload) -> Bool {
    let previous = saved
    saved.removeAll { $0.id == entry.id }
    guard persist() else {
      saved = previous
      message = "任务记录保存失败，记录已保留，请重试"
      return false
    }
    return true
  }
  @discardableResult func deleteCache(_ entry: SavedDownload) -> Bool {
    guard entry.cached == true else { return false }
    do {
      if FileManager.default.fileExists(atPath: entry.path) {
        try Self.removeCachedFile(URL(fileURLWithPath: entry.path))
      }
      if let sidecar = entry.danmakuPath, FileManager.default.fileExists(atPath: sidecar) {
        try Self.removeCachedFile(URL(fileURLWithPath: sidecar))
      }
      let xml = URL(fileURLWithPath: entry.path).deletingPathExtension().appendingPathExtension(
        "xml")
      if FileManager.default.fileExists(atPath: xml.path) {
        try Self.removeCachedFile(xml)
      }
      guard forget(entry) else {
        message = "缓存文件已清理，但任务记录保存失败；记录已保留，请重试"
        return false
      }
      return true
    } catch {
      message = error.localizedDescription
      return false
    }
  }
  private static func removeCachedFile(_ url: URL) throws {
    #if os(macOS)
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    #else
    try FileManager.default.removeItem(at: url)
    #endif
  }
  static func mux(video: URL, audio: URL, output: URL) async throws {
    let v = AVURLAsset(url: video)
    let a = AVURLAsset(url: audio)
    let mix = AVMutableComposition()
    let duration = try await v.load(.duration)
    guard let vt = try await v.loadTracks(withMediaType: .video).first,
      let at = try await a.loadTracks(withMediaType: .audio).first,
      let mv = mix.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let ma = mix.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    else { throw BiliError(text: "媒体不完整") }
    try mv.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: vt, at: .zero)
    let ad = try await a.load(.duration)
    try ma.insertTimeRange(
      CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, ad)), of: at, at: .zero)
    guard
      let exporter = AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetPassthrough)
    else { throw BiliError(text: "无法合并视频") }
    try await exporter.export(to: output, as: .mp4)
    try await Task.detached(priority: .utility) { try MP4Compatibility.normalizeOwnedFile(output) }.value
    try await validateMedia(output)
  }

}
