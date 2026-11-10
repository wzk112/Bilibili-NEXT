import Foundation
import ImageIO

actor ThumbnailCache {
  static let shared = ThumbnailCache()
  private let cache: URLCache
  private let networkSession: BiliNetworkSession
  private let decoded = NSCache<NSString, CGImage>()
  private var inFlight: [String: Task<CGImage, Error>] = [:]
  private var generation = UUID()
  init() {
    cache = URLCache(
      memoryCapacity: 0, diskCapacity: 128 * 1024 * 1024,
      directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BiliGlass/Thumbnails", isDirectory: true))
    let c = URLSessionConfiguration.default
    c.urlCache = cache
    c.httpCookieStorage = nil
    c.timeoutIntervalForRequest = 20
    networkSession = BiliNetworkSession(configuration: c)
    decoded.totalCostLimit = 32 * 1024 * 1024
    decoded.countLimit = 120
  }
  func data(_ url: URL) async throws -> Data {
    guard url.scheme == "https", let host = url.host,
      host == "hdslb.com" || host.hasSuffix(".hdslb.com") || host == "biliimg.com"
        || host.hasSuffix(".biliimg.com")
    else { throw BiliError(text: "封面地址无效") }
    let token = generation
    var request = URLRequest(url: url)
    API.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    let (data, response) = try await networkSession.session.data(for: request)
    try Task.checkCancellation()
    guard token == generation else { throw CancellationError() }
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      response.mimeType?.hasPrefix("image/") == true, data.count < 64 * 1024 * 1024
    else { throw BiliError(text: "封面不可用") }
    return data
  }
  /// Quantized sizes avoid re-decoding on each window-resize pixel.
  nonisolated static func pixelSize(_ requested: Int) -> Int {
    [128, 256, 512, 900].first { $0 >= requested } ?? 900
  }
  func thumbnail(_ url: URL, maxPixelSize: Int = 900) async throws -> CGImage {
    let pixels = Self.pixelSize(maxPixelSize)
    let key = "\(pixels)|\(url.absoluteString)"
    if let image = decoded.object(forKey: key as NSString) { return image }
    if let pending = inFlight[key] { return try await pending.value }
    let token = generation
    let pending = Task {
      let data = try await self.data(url)
      try Task.checkCancellation()
      return try await Self.decode(data, maxPixelSize: pixels)
    }
    inFlight[key] = pending
    defer { if token == generation { inFlight[key] = nil } }
    let image = try await pending.value
    try Task.checkCancellation()
    if token == generation { decoded.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height) }
    return image
  }
  static func decode(_ data: Data, maxPixelSize: Int = 900) async throws -> CGImage {
    try await Task.detached(priority: .utility) {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize(maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary)
      else { throw BiliError(text: "图片无法解码") }
      return image
    }.value
  }
  func trimMemory() {
    decoded.removeAllObjects()
  }
  func clear() {
    generation = UUID()
    inFlight.values.forEach { $0.cancel() }; inFlight.removeAll()
    decoded.removeAllObjects()
    cache.removeAllCachedResponses()
  }
}
