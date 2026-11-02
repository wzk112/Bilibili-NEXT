import Foundation
import Testing
@testable import BiliGlass

struct DownloadRemovalTests {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func entry(in root: URL, name: String, cached: Bool?) -> SavedDownload {
    SavedDownload(
      id: UUID(),
      video: Video(bvid: name, title: name, cover: "", author: "", duration: 10, views: 0),
      cid: 1, quality: "1080P", path: root.appendingPathComponent("\(name).mp4").path,
      date: .now, cached: cached,
      danmakuPath: root.appendingPathComponent("\(name).danmaku.json").path)
  }

  @Test @MainActor func forgettingRollsBackWhenTheIndexCannotBeSavedAndCanRetry() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let downloads = Downloads(storageDirectory: root)
    let first = entry(in: root, name: "first", cached: true)
    let second = entry(in: root, name: "second", cached: true)
    let bytes = Data("retained media".utf8)
    try bytes.write(to: URL(fileURLWithPath: first.path))
    downloads.saved = [first, second]
    let index = root.appendingPathComponent("downloads.json")
    // A directory at the index path deterministically rejects atomic file writes.
    try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)

    #expect(!downloads.forget(first))
    #expect(downloads.saved.map(\.id) == [first.id, second.id])
    #expect(downloads.message?.contains("记录已保留") == true)
    #expect(try Data(contentsOf: URL(fileURLWithPath: first.path)) == bytes)

    try FileManager.default.removeItem(at: index)
    #expect(downloads.forget(first))
    #expect(downloads.saved.map(\.id) == [second.id])
    #expect(Downloads(storageDirectory: root).saved.map(\.id) == [second.id])
    #expect(try Data(contentsOf: URL(fileURLWithPath: first.path)) == bytes)
  }

  @Test @MainActor func cacheRemovalRetainsARecordUntilTheIndexIsSaved() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let downloads = Downloads(storageDirectory: root)
    let cached = entry(in: root, name: "already-removed", cached: true)
    downloads.saved = [cached]
    let index = root.appendingPathComponent("downloads.json")
    try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
    // Files may already be absent after an earlier, partially completed deletion.
    #expect(!downloads.deleteCache(cached))
    #expect(downloads.saved.map(\.id) == [cached.id])
    #expect(downloads.message?.contains("缓存文件已清理") == true)
    #expect(downloads.message?.contains("请重试") == true)

    try FileManager.default.removeItem(at: index)
    #expect(downloads.deleteCache(cached))
    #expect(downloads.saved.isEmpty)
    #expect(Downloads(storageDirectory: root).saved.isEmpty)
  }

  @Test(arguments: [false, nil] as [Bool?])
  @MainActor func externalAndLegacyExportsKeepAllFiles(cached: Bool?) throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let downloads = Downloads(storageDirectory: root)
    let exported = entry(in: root, name: "export", cached: cached)
    let media = URL(fileURLWithPath: exported.path)
    let files = [media, URL(fileURLWithPath: try #require(exported.danmakuPath)),
      media.deletingPathExtension().appendingPathExtension("xml")]
    let bytes = Data("exported user file".utf8)
    for file in files { try bytes.write(to: file) }
    downloads.saved = [exported]
    #expect(downloads.persist())

    #expect(!downloads.deleteCache(exported))
    #expect(downloads.saved.map(\.id) == [exported.id])
    #expect(Downloads(storageDirectory: root).saved.map(\.id) == [exported.id])
    for file in files { #expect(try Data(contentsOf: file) == bytes) }

    #expect(downloads.forget(exported))
    #expect(Downloads(storageDirectory: root).saved.isEmpty)
    for file in files { #expect(try Data(contentsOf: file) == bytes) }
  }
}
