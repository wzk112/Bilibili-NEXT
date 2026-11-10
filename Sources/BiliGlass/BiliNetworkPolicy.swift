import BiliNetworking
import CFNetwork
import Foundation

/// Apply Bilibili-only exceptions to a private session, leaving macOS proxy settings intact.
enum BiliNetworkPolicy {
  static let preferenceKey = "bypassSystemProxy"
  static var bypassSystemProxy: Bool {
    #if os(macOS)
    UserDefaults.standard.bool(forKey: preferenceKey)
    #else
    false
    #endif
  }
  static let directDomains = [
    "bilibili.com", "hdslb.com", "biliimg.com", "bilivideo.com", "bilivideo.cn", "acgvideo.com", "b23.tv",
  ]

  static func proxySettings(bypass: Bool, system: [AnyHashable: Any]) -> [AnyHashable: Any]? {
    guard bypass else { return nil }
    var settings = system
    let key = "ExceptionsList"
    let existing = settings[key] as? [String] ?? []
    let additions = directDomains.flatMap { [$0, "*." + $0] }
    settings[key] = existing + additions.filter { !existing.contains($0) }
    return settings
  }

  static func configure(_ configuration: URLSessionConfiguration, bypass: Bool) {
    let system = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [AnyHashable: Any] ?? [:]
    configuration.connectionProxyDictionary = proxySettings(bypass: bypass, system: system)
  }

  static func usesSystemProxy(for url: URL) -> Bool {
    let host = url.host?.lowercased() ?? ""
    if bypassSystemProxy && directDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
    return CDNTransport.systemUsesProxy(for: url)
  }
}

/// Rebuild on the first request after a setting change. In-flight work keeps its
/// original session; new requests cannot reuse its proxy connections.
final class BiliNetworkSession: @unchecked Sendable {
  private let lock = NSLock()
  private let configuration: URLSessionConfiguration
  private let delegate: URLSessionDelegate?
  private let bypass: @Sendable () -> Bool
  private var current: (bypass: Bool, session: URLSession)?

  init(configuration: URLSessionConfiguration, delegate: URLSessionDelegate? = nil,
       bypass: @escaping @Sendable () -> Bool = { BiliNetworkPolicy.bypassSystemProxy }) {
    self.configuration = configuration.copy() as! URLSessionConfiguration
    self.delegate = delegate
    self.bypass = bypass
  }

  var session: URLSession {
    lock.withLock {
      let value = bypass()
      if let current, current.bypass == value { return current.session }
      let config = configuration.copy() as! URLSessionConfiguration
      BiliNetworkPolicy.configure(config, bypass: value)
      let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
      current?.session.finishTasksAndInvalidate()
      current = (value, session)
      return session
    }
  }

  deinit { current?.session.finishTasksAndInvalidate() }
}

/// Range reads share connections until the proxy preference changes. Every CDN
/// probe, audio/video read and download uses the same policy from its first request.
final class BiliMediaTransport: HTTPRangeStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private var current: (bypass: Bool, client: HTTPRangeStreamingClient)?
  private var client: HTTPRangeStreamingClient {
    lock.withLock {
      let bypass = BiliNetworkPolicy.bypassSystemProxy
      if let current, current.bypass == bypass { return current.client }
      let config = URLSessionConfiguration.ephemeral
      BiliNetworkPolicy.configure(config, bypass: bypass)
      let client = HTTPRangeStreamingClient(maximumConnectionsPerHost: 32,
        connectionProxyDictionary: config.connectionProxyDictionary)
      current = (bypass, client)
      return client
    }
  }

  func stream(from url: URL, rangeHeader: String, expectedRange: HTTPByteRange,
              expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
              requiresContentLength: Bool,
              onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
              onChunk: @escaping @Sendable (Data) async throws -> Void) async throws -> HTTPRangeStreamResult {
    try await client.stream(from: url, rangeHeader: rangeHeader, expectedRange: expectedRange,
      expectedCompleteLength: expectedCompleteLength, headers: headers, allowedContentTypes: allowedContentTypes,
      requiresContentLength: requiresContentLength, onResponse: onResponse, onChunk: onChunk)
  }
}
