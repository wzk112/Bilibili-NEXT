import BiliNetworking
import Foundation
import Synchronization

/// DASH 分段的远端来源：构造时校验媒体 CDN 来源与正长度，见 SECURITY-MODEL §4、§5。
public struct LoopbackRemoteResource: Sendable, Equatable {
    public let sourceURL: URL
    public let contentLength: Int64
    public let contentType: String
    public let headers: [String: String]

    public init(
        sourceURL: URL,
        contentLength: Int64,
        contentType: String,
        headers: [String: String] = [:]
    ) throws {
        guard BiliMediaCDNURLPolicy().allows(sourceURL) else {
            throw LoopbackPlaybackServerError.invalidRemoteSource
        }
        guard contentLength > 0 else {
            throw LoopbackPlaybackServerError.invalidContentLength(contentLength)
        }

        self.sourceURL = sourceURL
        self.contentLength = contentLength
        self.contentType = contentType
        self.headers = headers
    }
}

/// 单个 progressive item 的来源选择状态。
///
/// 首个通过响应头验证的完整 URL 会固定给后续 Range；选中的来源只经 `Mutex` 读写。
public final class LoopbackProgressiveResource: Sendable, Equatable {
    public let candidateURLs: [URL]
    public let contentLength: Int64
    public let contentType: String
    public let allowedUpstreamContentTypes: Set<String>
    public let headers: [String: String]

    private let selectedSourceURL = Mutex<URL?>(nil)

    public init(
        candidateURLs: [URL],
        contentLength: Int64,
        contentType: String,
        allowsOctetStreamWithContainerEvidence: Bool,
        headers: [String: String] = [:]
    ) throws {
        let mediaURLPolicy = BiliMediaCDNURLPolicy()
        guard !candidateURLs.isEmpty,
            candidateURLs.allSatisfy(mediaURLPolicy.allows)
        else {
            throw LoopbackPlaybackServerError.invalidProgressiveSource
        }
        guard contentLength > 0 else {
            throw LoopbackPlaybackServerError.invalidContentLength(contentLength)
        }
        guard contentType.caseInsensitiveCompare("video/mp4") == .orderedSame else {
            throw LoopbackPlaybackServerError.invalidProgressiveSource
        }
        self.candidateURLs = candidateURLs
        self.contentLength = contentLength
        self.contentType = contentType.lowercased()
        var allowed = Set([self.contentType])
        // 上游 Content-Type 只接受 `video/mp4`；调用方已有 MP4 容器证据时另外接受
        // `application/octet-stream`，见 SECURITY-MODEL §4。
        if allowsOctetStreamWithContainerEvidence {
            allowed.insert("application/octet-stream")
        }
        allowedUpstreamContentTypes = allowed
        self.headers = headers.removingCredentialAndRangeHeaders()
    }

    public static func == (
        lhs: LoopbackProgressiveResource,
        rhs: LoopbackProgressiveResource
    ) -> Bool {
        lhs === rhs
    }

    /// 已固定来源时只剩它，否则按顺序返回全部候选。
    var eligibleSourceURLs: [URL] {
        selectedSourceURL.withLock { selectedSourceURL in
            selectedSourceURL.map { [$0] } ?? candidateURLs
        }
    }

    /// 由 server 在上游响应头通过验证、向 AVPlayer 发出 206 之前调用。
    ///
    /// 首个调用的候选胜出并固定给后续 Range，之后只有同一 URL 返回 true；返回 false 时 server
    /// 取消本次响应。
    func select(_ url: URL) -> Bool {
        selectedSourceURL.withLock { selectedSourceURL in
            if let selectedSourceURL {
                return selectedSourceURL == url
            }
            guard candidateURLs.contains(url) else { return false }
            selectedSourceURL = url
            return true
        }
    }
}

/// 生成资源的配置错误、生成正文长度不合规与重试次数用尽。
public enum LoopbackGeneratedResourceError: Error, Sendable, Equatable {
    case invalidMaximumContentLength(Int)
    case invalidMaximumLoadAttempts(Int)
    case invalidGeneratedContentLength(Int)
    case loadAttemptsExhausted
}

/// 首次请求时生成正文；成功后只缓存于当前 loopback 会话，失败可由后续请求重试。
///
/// 拥有在途生成 Task 与缓存正文，状态只经 `Mutex` 访问：Task 在锁内创建并登记，等待在锁外。
/// generation 在每次开始生成与 `cancel()` 时递增；生成结束时与之比对，不一致即丢弃结果，旧生成不会
/// 写回缓存或清掉新的在途 Task。`cancel()` 之后的请求都以取消失败。
public final class LoopbackGeneratedResource: Sendable, Equatable {
    public let contentType: String

    /// 锁内状态：generation、剩余生成次数、是否已作废、缓存正文与在途生成 Task（见类型注释）。
    private struct State {
        var generation: UInt64 = 0
        var remainingLoadAttempts: Int
        var invalidated = false
        var cachedBody: Data?
        var loadTask: Task<Data, any Error>?
    }

    private let state: Mutex<State>
    private let maximumContentLength: Int
    private let cacheBody: Bool
    private let loader: @Sendable () async throws -> Data

    /// Set `cacheBody` to false for a refreshing live manifest. Concurrent readers
    /// still share one in-flight load; successful bodies are not retained.
    public init(
        contentType: String,
        maximumContentLength: Int,
        maximumLoadAttempts: Int = 2,
        cacheBody: Bool = true,
        loader: @escaping @Sendable () async throws -> Data
    ) throws {
        guard maximumContentLength > 0 else {
            throw LoopbackGeneratedResourceError.invalidMaximumContentLength(
                maximumContentLength
            )
        }
        guard maximumLoadAttempts > 0 else {
            throw LoopbackGeneratedResourceError.invalidMaximumLoadAttempts(
                maximumLoadAttempts
            )
        }
        self.contentType = contentType
        self.maximumContentLength = maximumContentLength
        self.cacheBody = cacheBody
        state = Mutex(State(remainingLoadAttempts: maximumLoadAttempts))
        self.loader = loader
    }

    public static func == (
        lhs: LoopbackGeneratedResource,
        rhs: LoopbackGeneratedResource
    ) -> Bool {
        lhs === rhs
    }

    /// 由 server 在响应前调用：有缓存直接返回，有在途生成就等它，否则在剩余次数内开始一次新生成。
    ///
    /// `cancel()` 之后或次数用尽时失败；生成出的正文为空或超过上限也算失败。
    func resolve() async throws -> Data {
        let pending = state.withLock { state -> (UInt64, Task<Data, any Error>, Data?) in
            guard !state.invalidated else {
                return (state.generation, Task { throw CancellationError() }, nil)
            }
            if let cachedBody = state.cachedBody {
                let cached = cachedBody
                return (state.generation, Task { cached }, cached)
            }
            if let loadTask = state.loadTask {
                return (state.generation, loadTask, nil)
            }
            guard state.remainingLoadAttempts > 0 else {
                return (
                    state.generation,
                    Task {
                        throw LoopbackGeneratedResourceError.loadAttemptsExhausted
                    },
                    nil
                )
            }
            state.remainingLoadAttempts -= 1
            state.generation &+= 1
            let loadGeneration = state.generation
            let task = Task {
                try await generateAndCache(generation: loadGeneration)
            }
            state.loadTask = task
            return (state.generation, task, nil)
        }
        if let cached = pending.2 {
            return cached
        }

        let body = try await pending.1.value
        try Task.checkCancellation()
        return body
    }

    private func generateAndCache(generation loadGeneration: UInt64) async throws -> Data {
        do {
            let body = try await loader()
            guard !body.isEmpty, body.count <= maximumContentLength else {
                throw LoopbackGeneratedResourceError.invalidGeneratedContentLength(
                    body.count
                )
            }
            let accepted = state.withLock { state -> Bool in
                guard state.generation == loadGeneration, !state.invalidated else {
                    return false
                }
                state.cachedBody = cacheBody ? body : nil
                state.loadTask = nil
                return true
            }
            guard accepted else { throw CancellationError() }
            return body
        } catch {
            state.withLock { state in
                if state.generation == loadGeneration {
                    state.loadTask = nil
                }
            }
            throw error
        }
    }

    /// 由 server `stop` 调用：作废缓存并取消在途生成，之后的 `resolve` 都以取消失败。
    func cancel() {
        let task = state.withLock { state -> Task<Data, any Error>? in
            state.generation &+= 1
            state.invalidated = true
            state.cachedBody = nil
            let task = state.loadTask
            state.loadTask = nil
            return task
        }
        task?.cancel()
    }
}

/// loopback route 背后的资源：内存正文、DASH 远端分段、按需生成的正文或 progressive 文件。
public enum LoopbackPlaybackResource: Sendable, Equatable {
    case inMemory(data: Data, contentType: String)
    case remote(LoopbackRemoteResource)
    case generated(LoopbackGeneratedResource)
    case progressive(LoopbackProgressiveResource)

    /// `.generated` 没有固定长度，server 必须先 `resolve` 成内存正文再取。
    var contentLength: Int64 {
        switch self {
        case .inMemory(let data, _):
            Int64(data.count)
        case .remote(let resource):
            resource.contentLength
        case .generated:
            preconditionFailure("Generated resources must be resolved before responding")
        case .progressive(let resource):
            resource.contentLength
        }
    }

    var contentType: String {
        switch self {
        case .inMemory(_, let contentType):
            contentType
        case .remote(let resource):
            resource.contentType
        case .generated(let resource):
            resource.contentType
        case .progressive(let resource):
            resource.contentType
        }
    }
}

/// 一条待登记的 route：session path 下的相对路径与它的资源，供成批原子登记。
public struct LoopbackRouteRegistration: Sendable, Equatable {
    public let relativePath: String
    public let resource: LoopbackPlaybackResource

    public init(
        relativePath: String,
        resource: LoopbackPlaybackResource
    ) {
        self.relativePath = relativePath
        self.resource = resource
    }
}

/// loopback server 的启动、route 登记、请求解析与来源校验错误。
public enum LoopbackPlaybackServerError: Error, Sendable, Equatable {
    case invalidContentLength(Int64)
    case invalidRoute(String)
    case duplicateRoute(String)
    case notStarted
    case listenerFailed(String)
    case invalidHTTPRequest
    case invalidProgressiveSource
    case invalidRemoteSource
}
