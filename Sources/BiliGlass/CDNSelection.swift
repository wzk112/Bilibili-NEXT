import BiliModels
import BiliNetworking
import CFNetwork
import Foundation

/// A selection is scoped to fresh playurl URLs. Alternate nodes may supply missing
/// bytes only after matching the selected resource's initialization/index and length.
struct CDNSelection: Sendable {
  let representation: MediaRepresentation
  let milliseconds: Int
  let candidateCount: Int
  var host: String { representation.primaryURL.host ?? "" }
}

actor CDNHealth {
  static let shared = CDNHealth()
  private var failures: [String: ContinuousClock.Instant] = [:]
  func failed(_ url: URL) {
    guard let host = url.host else { return }
    failures = failures.filter { $0.value > .now }
    if failures.count >= 64 { failures.removeAll() }
    failures[host] = .now + .seconds(30)
  }
  func candidates(_ urls: [URL]) -> [URL] {
    failures = failures.filter { $0.value > .now }
    var seen = Set<URL>()
    let unique = urls.filter { seen.insert($0).inserted }
    let healthy = unique.filter { failures[$0.host ?? ""] == nil }
    // A recovered connection must remain usable even if every host failed earlier.
    return Array((healthy.isEmpty ? unique : healthy).prefix(3))
  }
}

/// Shared connection pool, bounded metadata cache, and an idle (not total-download)
/// deadline. Waiting for the player to consume a chunk does not count as CDN silence.
final class CDNTransport: HTTPRangeStreaming, Sendable {
  private let source: any HTTPRangeStreaming
  private let prefixes = CDNPrefixes()
  private let probes = CDNProbeLog()
  private let transfers = CDNTransferStats()
  private let routes = CDNVerifiedRoutes()
  private let health: CDNHealth
  private let idleTimeout: Duration
  private let probeTimeout: Double
  private let rangeTimeout: Duration
  private let usesSystemProxy: @Sendable (URL) -> Bool

  init(source: any HTTPRangeStreaming = BiliMediaTransport(),
       health: CDNHealth = .shared, idleTimeout: Duration = .seconds(8),
       probeTimeout: Double = 3, rangeTimeout: Duration = .seconds(4),
       usesSystemProxy: @escaping @Sendable (URL) -> Bool = { _ in false }) {
    self.source = source
    self.health = health
    self.idleTimeout = idleTimeout
    self.probeTimeout = probeTimeout
    self.rangeTimeout = rangeTimeout
    self.usesSystemProxy = usesSystemProxy
  }

  func select(_ representation: MediaRepresentation, headers: [String: String]) async throws -> CDNSelection {
    try Task.checkCancellation()
    let candidates = await health.candidates(representation.urlCandidates)
    // The declared init/index end is guaranteed to be within the media. Unlike a
    // fixed 64 KiB request this also works for very short clips; cap probe traffic.
    let end = min(65_535, max(representation.segmentBase.initialization.endInclusive,
                             representation.segmentBase.index.endInclusive))
    let range = try HTTPByteRange(start: 0, endInclusive: end)
    let start = ContinuousClock.now
    let prefix = try await withThrowingTaskGroup(of: CDNPrefix?.self) { group in
      for url in candidates {
        group.addTask { [self] in
          let began = ContinuousClock.now
          do {
            // A cold proxy tunnel can take longer than a direct CDN probe.
            // Keep racing the candidates and return as soon as one is verified.
            let timeout = usesSystemProxy(url) ? max(probeTimeout, 10) : probeTimeout
            let prefix = try await withDeadline(seconds: timeout) {
              let buffer = CDNProbeBuffer()
              _ = try await self.stream(
                from: url, rangeHeader: range.headerValue, expectedRange: range,
                expectedCompleteLength: nil, headers: headers,
                allowedContentTypes: ["video/mp4", "audio/mp4", "application/octet-stream"],
                requiresContentLength: true,
                onResponse: { await buffer.header($0) },
                onChunk: { try await buffer.append($0, limit: range.length) })
              return try await buffer.finish(url: url, range: range)
            }
            await probes.record(url: url, kind: representation.kind.rawValue, began: began, result: "ok")
            return prefix
          } catch {
            try Task.checkCancellation()
            await probes.record(url: url, kind: representation.kind.rawValue, began: began, result: Self.failureName(error))
            await health.failed(url)
            return nil
          }
        }
      }
      defer { group.cancelAll() }
      while let result = try await group.next() {
        try Task.checkCancellation()
        if let result { return result }
      }
      throw BiliError(text: "当前播放线路响应超时或不可用，请重试")
    }
    try Task.checkCancellation()
    await prefixes.insert(prefix)
    let allCandidates = Array(representation.urlCandidates.prefix(3))
    await routes.register(prefix, candidates: allCandidates, kind: representation.kind.rawValue)
    for url in allCandidates { await transfers.register(url, kind: representation.kind.rawValue) }
    let duration = start.duration(to: .now).components
    let milliseconds = Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    let selected = MediaRepresentation(
      id: representation.id, kind: representation.kind, codecs: representation.codecs,
      mimeType: representation.mimeType, bandwidth: representation.bandwidth,
      videoAttributes: representation.videoAttributes, primaryURL: prefix.url,
      backupURLs: [], segmentBase: representation.segmentBase,
      initializationOverride: representation.initializationOverride)
    return CDNSelection(representation: selected, milliseconds: milliseconds, candidateCount: candidates.count)
  }

  func diagnostics() async -> [[String: String]] { await probes.items }
  func statistics() async -> [String: Int] { await transfers.snapshot() }
  func activeHosts() async -> [String: String] { await routes.diagnostics() }
  static func systemUsesProxy(for url: URL) -> Bool {
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
      let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]],
      let type = proxies.first?[kCFProxyTypeKey as String] as? String else { return false }
    return type != (kCFProxyTypeNone as String)
  }
  private static func failureName(_ error: Error) -> String {
    guard let error = error as? HTTPRangeResponseError else {
      return error is CDNIdleTimeout ? "idleTimeout" : error is BiliError ? "probeTimeout" : "transport"
    }
    switch error {
    case .statusCode(let code): return "HTTP \(code)"
    case .unsupportedContentType: return "unsupportedContentType"
    case .missingContentLength: return "missingContentLength"
    case .missingContentRange: return "missingContentRange"
    case .mismatchedContentRange: return "mismatchedContentRange"
    case .rejectedBody: return "invalidBody"
    case .bodyLengthMismatch: return "bodyLengthMismatch"
    case .transport(let kind): return kind
    default: return "invalidRangeResponse"
    }
  }

  func stream(
    from url: URL, rangeHeader: String, expectedRange: HTTPByteRange,
    expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
    requiresContentLength: Bool,
    onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
    onChunk: @escaping @Sendable (Data) async throws -> Void
  ) async throws -> HTTPRangeStreamResult {
    try Task.checkCancellation()
    if rangeHeader == expectedRange.headerValue,
       let cached = await prefixes.get(url), expectedRange.endInclusive <= cached.response.contentRange.endInclusive,
       expectedRange.start >= cached.response.contentRange.start {
      if let expectedCompleteLength, expectedCompleteLength != cached.response.contentRange.completeLength {
        throw HTTPRangeResponseError.rejectedBody
      }
      if let allowedContentTypes,
         !allowedContentTypes.contains(where: { $0.lowercased() == cached.response.contentType?.lowercased() }) {
        throw HTTPRangeResponseError.rejectedBody
      }
      let offset = Int(expectedRange.start - cached.response.contentRange.start)
      let data = cached.data.subdata(in: offset..<(offset + Int(expectedRange.length)))
      try await onResponse(HTTPRangeStreamResponse(
        contentRange: HTTPContentRange(start: expectedRange.start, endInclusive: expectedRange.endInclusive,
                                       completeLength: cached.response.contentRange.completeLength),
        contentLength: expectedRange.length, contentType: cached.response.contentType))
      try Task.checkCancellation()
      try await onChunk(data)
      return HTTPRangeStreamResult(byteCount: UInt64(data.count))
    }
    guard let route = await routes.get(url) else {
      return try await streamOnce(from: url, rangeHeader: rangeHeader, expectedRange: expectedRange,
        expectedCompleteLength: expectedCompleteLength, headers: headers, allowedContentTypes: allowedContentTypes,
        requiresContentLength: requiresContentLength, onResponse: onResponse, onChunk: onChunk)
    }
    // Some edge nodes have one damaged cached byte interval while the rest is fast.
    // Avoid that interval, rather than rerouting every video/audio request to a slow node.
    let candidates = await routes.ordered(url, range: expectedRange)
    let delivery = CDNDelivery(range: expectedRange)
    var last: Error = HTTPRangeResponseError.rejectedBody
    for candidate in candidates {
      try Task.checkCancellation()
      do {
        if candidate != route.anchor.url {
          _ = try await routes.verify(candidate, anchor: route.anchor) { [self] in
            let range = try HTTPByteRange(start: route.anchor.response.contentRange.start,
              endInclusive: route.anchor.response.contentRange.endInclusive)
            let buffer = CDNProbeBuffer()
            _ = try await streamOnce(from: candidate, rangeHeader: range.headerValue, expectedRange: range,
              expectedCompleteLength: route.anchor.response.contentRange.completeLength, headers: headers,
              allowedContentTypes: allowedContentTypes, requiresContentLength: true,
              onResponse: { await buffer.header($0) },
              onChunk: { try await buffer.append($0, limit: range.length) })
            return try await buffer.finish(url: candidate, range: range)
          }
        }
        let remaining = try await HTTPByteRange(start: expectedRange.start + Int64(delivery.bytes),
                                                endInclusive: expectedRange.endInclusive)
        _ = try await streamOnce(from: candidate, rangeHeader: remaining.headerValue, expectedRange: remaining,
          expectedCompleteLength: expectedCompleteLength ?? route.anchor.response.contentRange.completeLength,
          headers: headers, allowedContentTypes: allowedContentTypes, requiresContentLength: requiresContentLength,
          onResponse: { response in
            if let header = try await delivery.header(response) {
              do { try await onResponse(header) }
              catch { await delivery.consumerFailed(); throw error }
            }
          }, onChunk: { data in
            do { try await onChunk(data); try await delivery.accept(data.count) }
            catch { await delivery.consumerFailed(); throw error }
          })
        guard await delivery.bytes == expectedRange.length else { throw HTTPRangeResponseError.rejectedBody }
        await routes.recovered(url, from: candidates.first ?? url, to: candidate)
        return HTTPRangeStreamResult(byteCount: expectedRange.length)
      } catch {
        try Task.checkCancellation()
        guard await !delivery.downstreamFailed else { throw error }
        if await delivery.bytes == expectedRange.length { return HTTPRangeStreamResult(byteCount: expectedRange.length) }
        await routes.failed(candidate, range: expectedRange)
        last = error
        // Verification failures reject this candidate without consuming its media.
        // A different, independently verified API candidate can still repair the range.
      }
    }
    throw last
  }

  private func streamOnce(
    from url: URL, rangeHeader: String, expectedRange: HTTPByteRange,
    expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
    requiresContentLength: Bool,
    onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
    onChunk: @escaping @Sendable (Data) async throws -> Void
  ) async throws -> HTTPRangeStreamResult {
    let activity = CDNActivity()
    let began = ContinuousClock.now
    do {
      return try await withThrowingTaskGroup(of: HTTPRangeStreamResult.self) { group in
        group.addTask { [source, transfers] in
          try await source.stream(
            from: url, rangeHeader: rangeHeader, expectedRange: expectedRange,
            expectedCompleteLength: expectedCompleteLength, headers: headers,
            allowedContentTypes: allowedContentTypes, requiresContentLength: requiresContentLength,
            onResponse: { response in
              await activity.receivedResponse()
              await activity.consuming(true)
              do { try await onResponse(response) }
              catch { await activity.consumerFailed(); throw error }
              await activity.consuming(false)
            }, onChunk: { data in
              await transfers.record(url, bytes: data.count)
              await activity.consuming(true)
              do { try await onChunk(data) }
              catch { await activity.consumerFailed(); throw error }
              await activity.consuming(false)
            })
        }
        group.addTask { [idleTimeout, rangeTimeout] in
          while true {
            try await Task.sleep(for: min(idleTimeout / 4, .milliseconds(200)))
            if await activity.timedOut(after: idleTimeout, bodyBudget: expectedRange.length <= 1_048_576 ? rangeTimeout : nil) {
              throw CDNIdleTimeout()
            }
          }
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
      }
    } catch {
      try Task.checkCancellation()
      if await !activity.downstreamFailed {
        if error is CDNIdleTimeout { await health.failed(url) }
        await probes.record(url: url, kind: "media", began: began, result: Self.failureName(error) + " range=\(expectedRange.start)-\(expectedRange.endInclusive)")
      }
      throw error
    }
  }
}

struct CDNIdleTimeout: LocalizedError {
  var errorDescription: String? { "播放线路长时间未返回数据" }
}
private actor CDNActivity {
  var last = ContinuousClock.now
  var isConsuming = false
  var downstreamFailed = false
  var hasResponse = false
  var bodyBegan: ContinuousClock.Instant?
  var consumerBegan: ContinuousClock.Instant?
  var consumerTime: Duration = .zero
  func receivedResponse() { hasResponse = true; last = .now; bodyBegan = .now }
  func consumerFailed() { downstreamFailed = true }
  func consuming(_ value: Bool) {
    if value { consumerBegan = .now }
    else if let began = consumerBegan { consumerTime += began.duration(to: .now); consumerBegan = nil }
    isConsuming = value; last = .now
  }
  func timedOut(after duration: Duration, bodyBudget: Duration?) -> Bool {
    // URLSession can queue requests behind occupied connections before any response.
    // A short probe still has its own deadline, while normal media gets a first-response budget.
    guard !isConsuming else { return false }
    // A busy parallel transfer can take many seconds and still make progress.
    // Restart the deadline on every chunk instead of timing the whole block.
    return last.duration(to: .now) >= (hasResponse ? min(duration, bodyBudget ?? duration) : max(duration, .seconds(12)))
  }
}
private struct CDNPrefix: Sendable {
  let url: URL
  let response: HTTPRangeStreamResponse
  let data: Data
}
private struct CDNRoute: Sendable {
  let anchor: CDNPrefix
  let candidates: [URL]
  let kind: String
}
private actor CDNVerifiedRoutes {
  private var items: [URL: CDNRoute] = [:]
  private var preferred: [URL: URL] = [:]
  private var activeAnchors: [String: URL] = [:]
  private var switches: [URL: Int] = [:]
  private var verified: [URL: CDNPrefix] = [:]
  private var failures: [URL: [(HTTPByteRange, ContinuousClock.Instant)]] = [:]
  func register(_ prefix: CDNPrefix, candidates: [URL], kind: String) {
    items[prefix.url] = CDNRoute(anchor: prefix, candidates: candidates, kind: kind)
    activeAnchors[kind] = prefix.url
    preferred[prefix.url] = prefix.url; switches[prefix.url] = 0
    verified[prefix.url] = prefix
  }
  func get(_ url: URL) -> CDNRoute? { items[url] }
  func failed(_ url: URL, range: HTTPByteRange) {
    var rows = (failures[url] ?? []).filter { $0.1 > .now }
    rows.append((range, .now + .seconds(60)))
    failures[url] = Array(rows.suffix(32))
  }
  func ordered(_ url: URL, range: HTTPByteRange) -> [URL] {
    guard let route = items[url] else { return [url] }
    let current = preferred[url] ?? url
    let urls = [current] + ([url] + route.candidates).filter { $0 != current && $0 != url } + (current == url ? [] : [url])
    let blocked = urls.filter { candidate in
      (failures[candidate] ?? []).contains { r, until in
        until > .now && r.start <= range.endInclusive && range.start <= r.endInclusive
      }
    }
    return urls.filter { !blocked.contains($0) } + blocked
  }
  func recovered(_ anchor: URL, from failed: URL, to replacement: URL) {
    // Ignore late successes from requests that began before a route switch.
    guard preferred[anchor] == failed, failed != replacement else { return }
    preferred[anchor] = replacement
    switches[anchor, default: 0] += 1
  }
  func diagnostics() -> [String: String] {
    var result: [String: String] = [:]
    for (kind, anchor) in activeAnchors {
      result[kind + "Host"] = (preferred[anchor] ?? anchor).host ?? ""
      result[kind + "Switches"] = String(switches[anchor] ?? 0)
    }
    return result
  }
  func verify(_ url: URL, anchor: CDNPrefix,
              fetch: @Sendable () async throws -> CDNPrefix) async throws -> CDNPrefix {
    let candidate: CDNPrefix
    if let cached = verified[url] { candidate = cached }
    else { candidate = try await fetch() }
    guard candidate.response.contentRange == anchor.response.contentRange,
      candidate.data == anchor.data else { throw HTTPRangeResponseError.rejectedBody }
    verified[url] = candidate
    return candidate
  }
}
private actor CDNDelivery {
  let range: HTTPByteRange
  var bytes: UInt64 = 0
  var response: HTTPRangeStreamResponse?
  var downstreamFailed = false
  init(range: HTTPByteRange) { self.range = range }
  func consumerFailed() { downstreamFailed = true }
  func header(_ value: HTTPRangeStreamResponse) throws -> HTTPRangeStreamResponse? {
    if let response {
      guard response.contentRange.completeLength == value.contentRange.completeLength else {
        throw HTTPRangeResponseError.rejectedBody
      }
      return nil
    }
    let whole = try HTTPRangeStreamResponse(contentRange: HTTPContentRange(start: range.start,
      endInclusive: range.endInclusive, completeLength: value.contentRange.completeLength),
      contentLength: range.length, contentType: value.contentType)
    response = whole
    return whole
  }
  func accept(_ count: Int) throws {
    guard bytes + UInt64(count) <= range.length else { throw HTTPRangeResponseError.rejectedBody }
    bytes += UInt64(count)
  }
}
private actor CDNPrefixes {
  var items: [URL: CDNPrefix] = [:]
  func insert(_ prefix: CDNPrefix) {
    if items.count >= 8 { items.removeAll() }
    items[prefix.url] = prefix
  }
  func get(_ url: URL) -> CDNPrefix? { items[url] }
}
private actor CDNProbeBuffer {
  var response: HTTPRangeStreamResponse?
  var data = Data()
  func header(_ response: HTTPRangeStreamResponse) { self.response = response }
  func append(_ chunk: Data, limit: UInt64) throws {
    guard UInt64(data.count) + UInt64(chunk.count) <= limit else { throw HTTPRangeResponseError.rejectedBody }
    data.append(chunk)
  }
  func finish(url: URL, range: HTTPByteRange) throws -> CDNPrefix {
    guard let response, response.contentRange.start == range.start,
          response.contentRange.endInclusive == range.endInclusive,
          response.contentRange.completeLength != nil, response.contentLength == range.length,
          UInt64(data.count) == range.length else { throw HTTPRangeResponseError.rejectedBody }
    return CDNPrefix(url: url, response: response, data: data)
  }
}
private actor CDNProbeLog {
  var items: [[String: String]] = []
  func record(url: URL, kind: String, began: ContinuousClock.Instant, result: String) {
    let d = began.duration(to: .now).components
    items.append(["host": url.host ?? "", "kind": kind, "result": result,
                  "ms": String(d.seconds * 1_000 + d.attoseconds / 1_000_000_000_000_000)])
    if items.count > 24 { items.removeFirst(items.count - 24) }
  }
}
private actor CDNTransferStats {
  private var kinds: [URL: String] = [:]
  private var total: [String: Int] = [:]
  private var buckets: [Int: [String: Int]] = [:]
  private let started = ContinuousClock.now
  var hosts: [String: String] = [:]
  func register(_ url: URL, kind: String) { kinds[url] = kind }
  func record(_ url: URL, bytes: Int) {
    guard let kind = kinds[url] else { return }
    hosts[kind + "Host"] = url.host ?? ""
    let second = Int(started.duration(to: .now).components.seconds)
    total[kind, default: 0] += bytes
    buckets[second, default: [:]][kind, default: 0] += bytes
    buckets = buckets.filter { $0.key >= second - 3 }
  }
  func snapshot() -> [String: Int] {
    let second = Int(started.duration(to: .now).components.seconds)
    var result: [String: Int] = [:]
    for kind in ["video", "audio"] {
      let recent = buckets.filter { $0.key > second - 3 }.values.reduce(0) { $0 + ($1[kind] ?? 0) }
      result[kind + "Bytes"] = total[kind] ?? 0
      result[kind + "BytesPerSecond"] = recent / min(3, max(1, second + 1))
    }
    return result
  }
}
