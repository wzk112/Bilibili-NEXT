import Foundation
import Synchronization

/// 通过验证的 Range 响应头：`Content-Range`、正文长度（等于请求区间长度）与上游 `Content-Type`。
public struct HTTPRangeStreamResponse: Sendable, Equatable {
    public let contentRange: HTTPContentRange
    public let contentLength: UInt64
    public let contentType: String?

    public init(
        contentRange: HTTPContentRange,
        contentLength: UInt64,
        contentType: String?
    ) {
        self.contentRange = contentRange
        self.contentLength = contentLength
        self.contentType = contentType
    }
}

/// 一次流式读取完成时实际交给下游的字节数，等于请求区间长度。
public struct HTTPRangeStreamResult: Sendable, Equatable {
    public let byteCount: UInt64

    public init(byteCount: UInt64) {
        self.byteCount = byteCount
    }
}

/// 单来源 Range 流读取的 port；生产实现是 `HTTPRangeStreamingClient`。
///
/// bridge 的 SIDX、init 读取（经 `HTTPRangeClient`）与 loopback 媒体转发共用它。`onResponse`
/// 在响应头通过验证、正文放行之前调用，`onChunk` 返回前不交付下一个 chunk；
/// 任一回调抛错即取消上游请求（见 SECURITY-MODEL §4、§5）。
public protocol HTTPRangeStreaming: Sendable {
    /// `expectedCompleteLength` 为 nil 时不核对 `Content-Range` 的完整长度；`allowedContentTypes`
    /// 为 nil 时不限制上游 `Content-Type`；`requiresContentLength` 为 false 时允许上游省略
    /// `Content-Length`（正文长度仍按实际字节精确核对）。其余响应头逐项验证。
    func stream(
        from url: URL,
        rangeHeader: String,
        expectedRange: HTTPByteRange,
        expectedCompleteLength: Int64?,
        headers: [String: String],
        allowedContentTypes: Set<String>?,
        requiresContentLength: Bool,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPRangeStreamResult
}

/// 单来源媒体 Range 流。
///
/// 响应头在正文放行前完成验证，正文按 URLSession
/// chunk 交给下游；下游完成一个 chunk 后才恢复上游 task，避免把完整媒体积压在内存。
/// 同一实例的请求共用一个 URLSession 与其 CDN 连接；实例释放时取消在途请求并失效 session。
public final class HTTPRangeStreamingClient: HTTPRangeStreaming, Sendable {
    /// 两次收到数据之间的空闲上限：比基线的交互式 15 秒宽，取 URLSession 原生的 60 秒，
    /// CDN 首字节慢或下游暂停读取时不把仍在进行的媒体流判为失败。
    static let idleTimeout: TimeInterval = 60
    /// 整次传输的上限：取 URLSession 原生的七天，开放末尾 Range 随播放持续，分钟级绝对时限会截断它。
    static let resourceTimeout: TimeInterval = 7 * 24 * 60 * 60

    private let transport: URLSessionRangeTransport
    private let urlPolicy = PublicHTTPSURLPolicy()

    public convenience init() { self.init(maximumConnectionsPerHost: 6) }

    public convenience init(maximumConnectionsPerHost: Int, connectionProxyDictionary: [AnyHashable: Any]? = nil) {
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
        configuration.timeoutIntervalForRequest = Self.idleTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.httpMaximumConnectionsPerHost = max(1, min(32, maximumConnectionsPerHost))
        configuration.connectionProxyDictionary = connectionProxyDictionary
        self.init(transport: URLSessionRangeTransport(configuration: configuration))
    }

    init(transport: URLSessionRangeTransport) {
        self.transport = transport
    }

    public func stream(
        from url: URL,
        rangeHeader: String,
        expectedRange: HTTPByteRange,
        expectedCompleteLength: Int64?,
        headers: [String: String] = [:],
        allowedContentTypes: Set<String>?,
        requiresContentLength: Bool = true,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> HTTPRangeStreamResult {
        guard urlPolicy.allows(url) else {
            throw HTTPRangeResponseError.disallowedURL
        }
        guard (expectedCompleteLength ?? 1) > 0,
            rangeHeader.lowercased().hasPrefix("bytes="),
            !rangeHeader.contains(",")
        else {
            throw HTTPRangeResponseError.invalidRangeHeader
        }
        return try await transport.run(
            .rangeGET(url, rangeHeader: rangeHeader, headers: headers),
            operation: RangeStreamingOperation(
                validator: HTTPRangeResponseValidator(
                    expectedRange: expectedRange,
                    expectedCompleteLength: expectedCompleteLength,
                    requiresContentLength: requiresContentLength,
                    allowedContentTypes: allowedContentTypes.map {
                        Set($0.map { $0.lowercased() })
                    }
                ),
                onResponse: onResponse,
                onChunk: onChunk
            )
        )
    }

    deinit {
        transport.invalidate()
    }
}

/// 一次流式 Range 请求：验证响应头后逐 chunk 交给下游，下游处理期间挂起上游 task 形成背压。
///
/// 拥有 data task 与结束回调，直到 `finish` 把它们取出：取消 task、解除 transport 登记，再交付唯一
/// 结果。可变状态只经 `Mutex` 访问；挂起上游与登记回调在同一临界区，task 的恢复、取消与回调在锁外。
private final class RangeStreamingOperation: URLSessionRangeOperation, Sendable {
    /// 下游回调进行中时暂存的上游字节上限。
    ///
    /// `suspend()` 不保证立即停止已排队的 `didReceive data`，挂起后仍可能到达多个 chunk；
    /// 超过上限才判定失败，避免无界积压。
    private static let maximumPendingBytes = 4 * 1_024 * 1_024

    /// 一次请求的 task、结束回调、计数、回调进行中标记与暂存 chunk；只在 `state` 锁内读写。
    private struct State {
        var task: URLSessionDataTask?
        var onFinish: (@Sendable () -> Void)?
        var received: UInt64 = 0
        var responseAccepted = false
        var callbackInFlight = false
        var pendingChunk: Data?
        var upstreamCompleted = false
        var upstreamError: HTTPRangeResponseError?
        var finished = false

        var completionResult: HTTPRangeStreamResult {
            HTTPRangeStreamResult(byteCount: received)
        }
    }

    private let state = Mutex(State())
    private let validator: HTTPRangeResponseValidator
    private let expectedRange: HTTPByteRange
    private let suspendsTask: Bool
    private let onResponse: @Sendable (HTTPRangeStreamResponse) async throws -> Void
    private let onChunk: @Sendable (Data) async throws -> Void
    private let outcome = OneShotResult<HTTPRangeStreamResult>()

    init(
        validator: HTTPRangeResponseValidator,
        onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) {
        self.validator = validator
        expectedRange = validator.expectedRange
        // A small Range is already a hard memory bound; do not suspend and resume
        // the task for every tiny chunk. Large/open-ended transfers keep backpressure.
        suspendsTask = validator.expectedRange.length > 1_048_576
        self.onResponse = onResponse
        self.onChunk = onChunk
    }

    func start(
        _ task: URLSessionDataTask,
        onFinish: @escaping @Sendable () -> Void
    ) async throws -> HTTPRangeStreamResult {
        let shouldStart = state.withLock { state in
            guard !state.finished else { return false }
            state.task = task
            state.onFinish = onFinish
            return true
        }
        if shouldStart {
            task.resume()
        } else {
            task.cancel()
            onFinish()
        }
        return try await outcome.value()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func receive(
        _ response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let disposition = ResponseDispositionHandler(completionHandler)
        do {
            let validated = try validator.validate(response)
            guard beginCallback() else {
                disposition.call(.cancel)
                return
            }
            Task {
                do {
                    try await onResponse(validated)
                    let shouldAllow = state.withLock { state in
                        state.callbackInFlight = false
                        state.responseAccepted = !state.finished
                        return !state.finished
                    }
                    disposition.call(shouldAllow ? .allow : .cancel)
                } catch {
                    disposition.call(.cancel)
                    finish(.failure(error))
                }
            }
        } catch {
            disposition.call(.cancel)
            finish(.failure(error))
        }
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        enum Action {
            case process(URLSessionDataTask)
            case queued
            case fail(HTTPRangeResponseError)
            case ignore
        }
        let action = state.withLock { state -> Action in
            guard !state.finished, state.responseAccepted else { return .ignore }
            let next = state.received + UInt64(data.count)
            guard next <= expectedRange.length else {
                return .fail(
                    .bodyLengthMismatch(
                        expected: expectedRange.length,
                        actual: next
                    )
                )
            }
            state.received = next
            if state.callbackInFlight {
                let pending = (state.pendingChunk ?? Data()) + data
                guard pending.count <= Self.maximumPendingBytes else {
                    return .fail(
                        .transport(errorType: "BufferedRangeChunkOverflow")
                    )
                }
                state.pendingChunk = pending
                return .queued
            }
            guard let task = state.task else { return .ignore }
            state.callbackInFlight = true
            // 与登记回调在同一临界区挂起：其他 chunk 看到 callbackInFlight 时上游一定已挂起。
            if suspendsTask { task.suspend() }
            return .process(task)
        }
        switch action {
        case .process(let task):
            Task { await processChunks(startingWith: data, task: task) }
        case .queued, .ignore:
            break
        case .fail(let error):
            finish(.failure(error))
        }
    }

    private func processChunks(startingWith firstChunk: Data, task: URLSessionDataTask) async {
        var chunk = firstChunk
        do {
            while true {
                try await onChunk(chunk)
                let step = state.withLock {
                    state -> (next: Data?, completion: Result<HTTPRangeStreamResult, HTTPRangeResponseError>?, resume: Bool) in
                    guard !state.finished else { return (nil, nil, false) }
                    if let pendingChunk = state.pendingChunk {
                        state.pendingChunk = nil
                        return (pendingChunk, nil, false)
                    }
                    state.callbackInFlight = false
                    if state.upstreamCompleted {
                        return (nil, state.upstreamError.map { .failure($0) } ?? .success(state.completionResult), false)
                    }
                    return (nil, nil, true)
                }
                if let next = step.next {
                    chunk = next
                    continue
                }
                if let completion = step.completion {
                    finish(completion.mapError { $0 as any Error })
                } else if step.resume && suspendsTask {
                    task.resume()
                }
                return
            }
        } catch {
            finish(.failure(error))
        }
    }

    func complete(error: (any Error)?) {
        let upstreamError = error.map {
            HTTPRangeResponseError.transport(errorType: ($0 as NSError).domain == NSURLErrorDomain
                ? "NSURLError(\(($0 as NSError).code))" : String(reflecting: type(of: $0)))
        }
        let completion = state.withLock { state -> Result<HTTPRangeStreamResult, any Error>? in
            guard !state.finished else { return nil }
            state.upstreamCompleted = true
            state.upstreamError = upstreamError
            // Drain accepted data before surfacing a disconnect. Otherwise a suffix
            // retry can race the preceding chunk callback and duplicate media bytes.
            guard !state.callbackInFlight else { return nil }
            return upstreamError.map { .failure($0) } ?? .success(state.completionResult)
        }
        if let completion {
            finish(completion)
        }
    }

    private func beginCallback() -> Bool {
        state.withLock { state in
            guard !state.finished, !state.callbackInFlight else { return false }
            state.callbackInFlight = true
            return true
        }
    }

    private func finish(_ result: Result<HTTPRangeStreamResult, any Error>) {
        let resources = state.withLock { state in
            guard !state.finished else {
                return (
                    nil as Result<HTTPRangeStreamResult, any Error>?,
                    nil as URLSessionDataTask?,
                    nil as (@Sendable () -> Void)?
                )
            }
            let finalResult: Result<HTTPRangeStreamResult, any Error>
            switch result {
            case .success where state.received != expectedRange.length:
                finalResult = .failure(
                    HTTPRangeResponseError.bodyLengthMismatch(
                        expected: expectedRange.length,
                        actual: state.received
                    )
                )
            default:
                finalResult = result
            }
            state.finished = true
            let task = state.task
            state.task = nil
            let onFinish = state.onFinish
            state.onFinish = nil
            return (finalResult, task, onFinish)
        }
        guard let finalResult = resources.0 else { return }
        resources.1?.cancel()
        resources.2?()
        outcome.resolve(finalResult)
    }
}

/// URLSession 的响应处置回调只调用一次：先到的放行或取消生效，之后的调用忽略。
///
/// `@unchecked Sendable` 由 `lock` 保证：回调在锁内取出、锁外调用。不用 `Mutex`：回调是 URLSession
/// delegate 传进来的非 Sendable 闭包，把外部传入的非 Sendable 值存进 `Mutex`（初始化的 `sending`
/// 参数）会被 region 检查拒绝。
private final class ResponseDispositionHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLSession.ResponseDisposition) -> Void)?

    init(_ handler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.handler = handler
    }

    func call(_ disposition: URLSession.ResponseDisposition) {
        let handler = lock.withLock {
            let handler = self.handler
            self.handler = nil
            return handler
        }
        handler?(disposition)
    }
}
