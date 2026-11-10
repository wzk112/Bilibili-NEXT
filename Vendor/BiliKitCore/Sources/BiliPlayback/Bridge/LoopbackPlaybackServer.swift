import BiliNetworking
import Foundation
@preconcurrency import Network
import Synchronization

private struct LoopbackResponseAlreadyStartedError: Error {}

/// 向 AVPlayer 暴露最小、会话隔离的 HTTP/1.1 HLS/Range surface。
///
/// Server 只绑定 `127.0.0.1`，要求随机 path 与精确 Host，并对远端媒体强制 Range。
/// `stop` 会原子移除 listener、route、connection 与上游 Task，可安全重复调用；deinit 兜底调用它。
///
/// listener、端口、route、连接与在途 Task 都在 `Mutex` 持有的 `State` 里：登记与移除在锁内完成，
/// Network 对象的 cancel 与 Task 的取消带出锁外执行。唯一例外是撤销未完成的启动（`cancelStart`）：
/// 只在登记的仍是这个 listener 时移除并 cancel，两步在同一临界区完成。
public final class LoopbackPlaybackServer: Sendable {
    /// 请求头上限，超出回 431，见 SECURITY-MODEL §5。
    private static let maximumHeaderBytes = 16 * 1_024
    /// 同时保持的连接上限；AVPlayer 的并发请求远低于此。
    static let maximumConcurrentConnections = 32
    /// 尚未收齐请求头的连接上限，低于总上限，保证进入响应阶段的连接总有余量。
    ///
    /// 名额满时关闭最早接受、仍未发完请求头的连接给新连接让位，空闲连接不能把 AVPlayer 挡在门外；
    /// 只有全部连接都在响应阶段且达到总上限时，新连接才被直接关闭。
    static let maximumPendingHeaderConnections = 16
    /// 从接受连接到收齐请求头的时限；超时关闭，空闲或慢速连接不能长期占住连接名额。
    private static let requestHeaderTimeout: DispatchTimeInterval = .seconds(10)

    /// 锁内的 listener、端口、route 与连接登记表；`nextPendingHeaderOrder` 只增，
    /// 名额满时据此选出最早的连接让位。
    private struct State {
        var listener: NWListener?
        var port: NWEndpoint.Port?
        var routes: [String: LoopbackPlaybackResource] = [:]
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var connectionTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        var pendingHeaders: [ObjectIdentifier: PendingHeader] = [:]
        var nextPendingHeaderOrder: UInt64 = 0

        /// 从登记表移除一条连接的全部资源并让出名额；返回值交给调用方在锁外收尾。
        mutating func detach(_ id: ObjectIdentifier) -> DetachedConnection {
            DetachedConnection(
                connection: connections.removeValue(forKey: id),
                task: connectionTasks.removeValue(forKey: id),
                headerDeadline: pendingHeaders.removeValue(forKey: id)?.deadline
            )
        }
    }

    private let queue: DispatchQueue
    private let state = Mutex(State())
    private let rangeStreamer: any HTTPRangeStreaming
    /// 每实例随机的 session path 段，只有它下面的 route 可访问，见 SECURITY-MODEL §5。
    private let sessionToken: String

    public init(
        rangeStreamer: any HTTPRangeStreaming = HTTPRangeStreamingClient()
    ) {
        self.rangeStreamer = rangeStreamer
        queue = DispatchQueue(label: "com.shiinayane.BiliKit.loopback-playback")
        sessionToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    deinit {
        stop()
    }

    /// 启动并等待 listener 得到实际端口；调用方取消会同步撤销未完成的启动。
    public func start() async throws {
        if state.withLock({ $0.listener != nil && $0.port != nil }) {
            return
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw LoopbackPlaybackServerError.listenerFailed(
                String(reflecting: type(of: error))
            )
        }

        let started = OneShotResult<Void>()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                guard let self, let boundPort = listener?.port else {
                    started.resolve(
                        .failure(
                            LoopbackPlaybackServerError.listenerFailed(
                                "Listener became ready without a port"
                            )
                        )
                    )
                    return
                }
                self.state.withLock {
                    $0.port = boundPort
                }
                started.resolve(.success(()))
            case .failed(let error):
                started.resolve(
                    .failure(
                        LoopbackPlaybackServerError.listenerFailed(
                            String(describing: error)
                        )
                    )
                )
            case .cancelled:
                started.resolve(
                    .failure(
                        LoopbackPlaybackServerError.listenerFailed(
                            "Listener cancelled before becoming ready"
                        )
                    )
                )
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        state.withLock {
            $0.listener = listener
        }

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            listener.start(queue: queue)
            try await started.value()
            try Task.checkCancellation()
        } onCancel: {
            started.resolve(.failure(CancellationError()))
            self.cancelStart(listener)
        }
    }

    /// 把资源登记在本 session token 下；返回 URL 不泄露远端来源。
    public func register(
        _ resource: LoopbackPlaybackResource,
        at relativePath: String
    ) throws -> URL {
        try register([
            LoopbackRouteRegistration(
                relativePath: relativePath,
                resource: resource
            )
        ])[0]
    }

    /// 先验证完整集合，再在同一锁内登记，避免 master 可见时轨道 route 仍不完整。
    public func register(
        _ registrations: [LoopbackRouteRegistration]
    ) throws -> [URL] {
        var seen = Set<String>()
        let prepared = try registrations.map { registration in
            let url = try url(for: registration.relativePath)
            guard seen.insert(url.path).inserted else {
                throw LoopbackPlaybackServerError.duplicateRoute(
                    registration.relativePath
                )
            }
            return (url, registration.resource)
        }
        try state.withLock { state in
            for (url, _) in prepared where state.routes[url.path] != nil {
                throw LoopbackPlaybackServerError.duplicateRoute(url.path)
            }
            for (url, resource) in prepared {
                state.routes[url.path] = resource
            }
        }
        return prepared.map(\.0)
    }

    /// Remove expired live-playlist routes without disturbing active responses.
    public func unregister(at relativePath: String) throws {
        let url = try url(for: relativePath)
        let removed = state.withLock { $0.routes.removeValue(forKey: url.path) }
        if case .generated(let resource) = removed { resource.cancel() }
    }

    public func url(for relativePath: String) throws -> URL {
        guard isValidRoute(relativePath) else {
            throw LoopbackPlaybackServerError.invalidRoute(relativePath)
        }
        guard let port = state.withLock({ $0.port }) else {
            throw LoopbackPlaybackServerError.notStarted
        }

        let route = "/\(sessionToken)/\(relativePath)"
        return try requireURL(
            "http://127.0.0.1:\(port.rawValue)\(route)"
        )
    }

    /// 关闭 listener、所有活动连接与远端 Range Task，并清空内存 route。
    public func stop() {
        let released = state.withLock {
            state -> (
                NWListener?,
                [NWConnection],
                [Task<Void, Never>],
                [LoopbackPlaybackResource],
                [DispatchWorkItem]
            ) in
            let released = (
                state.listener,
                Array(state.connections.values),
                Array(state.connectionTasks.values),
                Array(state.routes.values),
                state.pendingHeaders.values.map(\.deadline)
            )
            state.listener = nil
            state.port = nil
            state.routes.removeAll()
            state.connections.removeAll()
            state.connectionTasks.removeAll()
            state.pendingHeaders.removeAll()
            return released
        }

        released.0?.cancel()
        for deadline in released.4 {
            deadline.cancel()
        }
        for connection in released.1 {
            connection.cancel()
        }
        for task in released.2 {
            task.cancel()
        }
        cancelGeneratedResources(in: released.3)
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let admission = state.withLock {
            state -> (headerDeadline: DispatchWorkItem?, evicted: DetachedConnection?) in
            guard state.listener != nil else { return (nil, nil) }
            var evicted: DetachedConnection?
            if state.pendingHeaders.count >= Self.maximumPendingHeaderConnections
                || state.connections.count >= Self.maximumConcurrentConnections
            {
                guard
                    let oldest = state.pendingHeaders.min(by: {
                        $0.value.order < $1.value.order
                    })?.key
                else {
                    return (nil, nil)
                }
                evicted = state.detach(oldest)
            }
            // 在临界区里创建：`DispatchWorkItem` 不是 Sendable，从锁外捕获进来再存入 `Mutex` 的状态
            // 会被 region 检查拒绝。它到登记之后才在锁外排期，创建位置不影响时序。它同时被 State 与
            // 锁外的排期持有，这部分安全靠 libdispatch 的 cancel／perform 线程安全，不由编译器检查。
            let headerDeadline = DispatchWorkItem { [weak self] in
                self?.closeConnection(id)
            }
            state.connections[id] = connection
            state.pendingHeaders[id] = PendingHeader(
                deadline: headerDeadline,
                order: state.nextPendingHeaderOrder
            )
            state.nextPendingHeaderOrder &+= 1
            return (headerDeadline, evicted)
        }
        admission.evicted?.close()
        guard let headerDeadline = admission.headerDeadline else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.detachConnection(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(
            deadline: .now() + Self.requestHeaderTimeout,
            execute: headerDeadline
        )
        receiveRequestHeader(on: connection, id: id, accumulated: Data())
    }

    private func cancelStart(_ listener: NWListener) {
        state.withLock { state in
            guard state.listener === listener else { return }
            state.listener = nil
            state.port = nil
            listener.cancel()
        }
    }

    private func receiveRequestHeader(
        on connection: NWConnection,
        id: ObjectIdentifier,
        accumulated: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumHeaderBytes
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data {
                buffer.append(data)
            }
            guard buffer.count <= Self.maximumHeaderBytes else {
                self.sendStatus(431, reason: "Request Header Fields Too Large", on: connection)
                return
            }

            let delimiter = Data("\r\n\r\n".utf8)
            if let headerEnd = buffer.range(of: delimiter)?.upperBound {
                let header = buffer.subdata(in: 0..<headerEnd)
                self.state.withLock {
                    $0.pendingHeaders.removeValue(forKey: id)
                }?.deadline.cancel()
                self.beginResponse(for: header, on: connection, id: id)
            } else if isComplete {
                self.sendStatus(400, reason: "Bad Request", on: connection)
            } else {
                self.receiveRequestHeader(
                    on: connection,
                    id: id,
                    accumulated: buffer
                )
            }
        }
    }

    /// 响应期间监听下游断开，立即关闭连接并取消上游 Task，不让上游请求白跑。
    ///
    /// 请求头之后 AVPlayer 不再发送数据：EOF 或连接错误即断开，之后到达的字节直接丢弃。
    private func watchForDownstreamClose(
        on connection: NWConnection,
        id: ObjectIdentifier
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumHeaderBytes
        ) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.closeConnection(id)
            } else {
                self.watchForDownstreamClose(on: connection, id: id)
            }
        }
    }

    private func beginResponse(
        for headerData: Data,
        on connection: NWConnection,
        id: ObjectIdentifier
    ) {
        let request: LoopbackHTTPRequest
        do {
            request = try LoopbackHTTPRequest.parse(headerData)
        } catch {
            sendStatus(400, reason: "Bad Request", on: connection)
            return
        }

        guard request.method == "GET" || request.method == "HEAD" else {
            sendStatus(
                405,
                reason: "Method Not Allowed",
                headers: ["Allow": "GET, HEAD"],
                on: connection
            )
            return
        }
        // Host 必须与 `127.0.0.1:<端口>` 精确相等，挡住 DNS rebinding 把别的站点解析到本机端口，
        // 见 SECURITY-MODEL §5。
        guard let expectedHostHeader,
            request.headers["host"] == expectedHostHeader
        else {
            sendStatus(400, reason: "Bad Request", on: connection)
            return
        }
        // 目标必须在本实例的随机 session path 下，其他实例或猜测的路径一律 404，见 SECURITY-MODEL §5。
        guard request.target.hasPrefix("/\(sessionToken)/") else {
            sendStatus(404, reason: "Not Found", on: connection)
            return
        }
        guard
            let resource = state.withLock({ $0.routes[request.target] })
        else {
            sendStatus(404, reason: "Not Found", on: connection)
            return
        }

        let task = Task { [weak self, weak connection] in
            guard let self, let connection else { return }
            do {
                try await self.respond(
                    to: request,
                    with: resource,
                    on: connection
                )
            } catch is CancellationError {
                connection.cancel()
            } catch is LoopbackResponseAlreadyStartedError {
                connection.cancel()
            } catch {
                self.sendStatus(502, reason: "Bad Gateway", on: connection)
            }
        }
        // 创建 Task 期间可能已 stop 或连接已关闭：锁内确认连接与 route 仍登记才交出 Task，
        // 否则立即取消。
        let accepted = state.withLock { state -> Bool in
            guard state.connections[id] != nil,
                state.routes[request.target] == resource
            else {
                return false
            }
            state.connectionTasks[id] = task
            return true
        }
        if accepted {
            watchForDownstreamClose(on: connection, id: id)
        } else {
            task.cancel()
            connection.cancel()
        }
    }

    private func respond(
        to request: LoopbackHTTPRequest,
        with resource: LoopbackPlaybackResource,
        on connection: NWConnection
    ) async throws {
        if case .generated(let generated) = resource {
            let body = try await generated.resolve()
            try Task.checkCancellation()
            try await respond(
                to: request,
                with: .inMemory(
                    data: body,
                    contentType: generated.contentType
                ),
                on: connection
            )
            return
        }
        if request.method == "HEAD" {
            sendResponse(
                status: 200,
                reason: "OK",
                headers: responseHeaders(
                    for: resource,
                    bodyLength: 0,
                    range: nil,
                    isHead: true
                ),
                body: Data(),
                on: connection
            )
            return
        }

        let requestedRange: HTTPByteRange?
        let requestedRangeHeader: String?
        switch parseRange(
            request.headers["range"],
            contentLength: resource.contentLength
        ) {
        case .ignored:
            requestedRange = nil
            requestedRangeHeader = nil
        case .satisfiable(let headerValue, let range):
            requestedRange = range
            requestedRangeHeader = headerValue
        case .unsatisfiable:
            sendStatus(
                416,
                reason: "Range Not Satisfiable",
                headers: [
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-store",
                    "Content-Range": "bytes */\(resource.contentLength)",
                    "Content-Type": resource.contentType
                ],
                on: connection
            )
            return
        }

        switch resource {
        case .inMemory(let data, _):
            let body: Data
            if let requestedRange {
                body = data.subdata(
                    in: Int(requestedRange.start)..<(Int(requestedRange.endInclusive) + 1)
                )
            } else {
                body = data
            }
            sendResponse(
                status: requestedRange == nil ? 200 : 206,
                reason: requestedRange == nil ? "OK" : "Partial Content",
                headers: responseHeaders(
                    for: resource,
                    bodyLength: body.count,
                    range: requestedRange,
                    isHead: false
                ),
                body: body,
                on: connection
            )
        case .remote(let remote):
            guard let requestedRange else {
                sendStatus(400, reason: "Range Required", on: connection)
                return
            }
            // DASH 分段只向 SIDX 成功的来源转发解析后的闭区间 Range；部分 CDN／HTTP/2 省略
            // Content-Length，正文长度由逐字节计数保证，因此不强制该头。
            try await streamRange(
                requestedRange,
                rangeHeader: requestedRange.headerValue,
                of: resource,
                sourceURLs: [remote.sourceURL],
                headers: remote.headers,
                allowedUpstreamContentTypes: nil,
                requiresUpstreamContentLength: false,
                selectSource: { _ in true },
                on: connection
            )
        case .progressive(let progressive):
            guard let requestedRange, let requestedRangeHeader else {
                sendStatus(400, reason: "Range Required", on: connection)
                return
            }
            // progressive 保留 AVPlayer 原始的单一 Range 头。
            try await streamRange(
                requestedRange,
                rangeHeader: requestedRangeHeader,
                of: resource,
                sourceURLs: progressive.eligibleSourceURLs,
                headers: progressive.headers,
                allowedUpstreamContentTypes: progressive.allowedUpstreamContentTypes,
                requiresUpstreamContentLength: true,
                selectSource: progressive.select,
                on: connection
            )
        case .generated:
            preconditionFailure("Generated resource was not resolved")
        }
    }

    /// 按候选顺序把上游 Range 逐 chunk 转发给 AVPlayer，每个 chunk 等待 send completion。
    ///
    /// 只有尚未发送响应头的候选在上游失败时才会尝试下一个来源；已发送 206 后失败只能断开连接。
    /// 下游发送失败按取消处理，不换备用线路。
    private func streamRange(
        _ range: HTTPByteRange,
        rangeHeader: String,
        of resource: LoopbackPlaybackResource,
        sourceURLs: [URL],
        headers: [String: String],
        allowedUpstreamContentTypes: Set<String>?,
        requiresUpstreamContentLength: Bool,
        selectSource: @escaping @Sendable (URL) -> Bool,
        on connection: NWConnection
    ) async throws {
        var headHeaders = responseHeaders(
            for: resource,
            bodyLength: Int(range.length),
            range: range,
            isHead: false
        )
        headHeaders["Connection"] = "close"
        let head = Self.responseHead(
            status: 206,
            reason: "Partial Content",
            headers: headHeaders
        )
        var lastError: (any Error)?
        for sourceURL in sourceURLs {
            try Task.checkCancellation()
            let responseStarted = LockedFlag()
            do {
                let result = try await rangeStreamer.stream(
                    from: sourceURL,
                    rangeHeader: rangeHeader,
                    expectedRange: range,
                    expectedCompleteLength: resource.contentLength,
                    headers: headers,
                    allowedContentTypes: allowedUpstreamContentTypes,
                    requiresContentLength: requiresUpstreamContentLength,
                    onResponse: { [weak connection] _ in
                        guard selectSource(sourceURL), let connection else {
                            throw CancellationError()
                        }
                        try await Self.sendChunk(head, on: connection)
                        responseStarted.set()
                    },
                    onChunk: { [weak connection] chunk in
                        guard let connection else { throw CancellationError() }
                        try await Self.sendChunk(chunk, on: connection)
                    }
                )
                guard result.byteCount == range.length else {
                    throw HTTPRangeResponseError.bodyLengthMismatch(
                        expected: range.length,
                        actual: result.byteCount
                    )
                }
                connection.cancel()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if responseStarted.value {
                    throw LoopbackResponseAlreadyStartedError()
                }
            }
        }
        throw lastError ?? LoopbackPlaybackServerError.invalidProgressiveSource
    }

    /// 下游写入失败说明 AVPlayer 已断开，报告为 `CancellationError`。
    private static func sendChunk(
        _ data: Data,
        on connection: NWConnection
    ) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if error != nil {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
        try Task.checkCancellation()
    }

    private func sendStatus(
        _ status: Int,
        reason: String,
        headers: [String: String] = [:],
        on connection: NWConnection
    ) {
        sendResponse(
            status: status,
            reason: reason,
            headers: headers,
            body: Data(),
            on: connection
        )
    }

    private func sendResponse(
        status: Int,
        reason: String,
        headers: [String: String],
        body: Data,
        on connection: NWConnection
    ) {
        var responseHeaders = headers
        responseHeaders["Connection"] = "close"
        responseHeaders["Content-Length"] =
            responseHeaders["Content-Length"]
            ?? "\(body.count)"
        var response = Self.responseHead(
            status: status,
            reason: reason,
            headers: responseHeaders
        )
        response.append(body)

        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    /// 先在锁内释放连接名额再关闭，客户端看到断开时 server 已可接受新连接。
    private func closeConnection(_ id: ObjectIdentifier) {
        state.withLock { $0.detach(id) }.close()
    }

    private func detachConnection(_ id: ObjectIdentifier) {
        state.withLock { $0.detach(id) }.cancelPendingWork()
    }

    /// 登记的相对路径只允许字母数字与 `-._/`，不能含 `..` 或首尾 `/`，
    /// 生成的 URL 不会逃出 session path。
    private func isValidRoute(_ route: String) -> Bool {
        guard !route.isEmpty,
            !route.hasPrefix("/"),
            !route.hasSuffix("/"),
            !route.contains("..")
        else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._/")
        )
        return route.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func cancelGeneratedResources(
        in resources: [LoopbackPlaybackResource]
    ) {
        for case .generated(let resource) in resources {
            resource.cancel()
        }
    }

    private var expectedHostHeader: String? {
        state.withLock { state in
            state.port.map { "127.0.0.1:\($0.rawValue)" }
        }
    }
}

private struct PendingHeader {
    let deadline: DispatchWorkItem
    /// 接受顺序；名额满时让最早的连接让位。
    let order: UInt64
}

/// 已从登记表移除、尚待在锁外收尾的连接资源。
private struct DetachedConnection {
    let connection: NWConnection?
    let task: Task<Void, Never>?
    let headerDeadline: DispatchWorkItem?

    func cancelPendingWork() {
        task?.cancel()
        headerDeadline?.cancel()
    }

    func close() {
        cancelPendingWork()
        connection?.cancel()
    }
}

/// 记录当前候选是否已向下游发出 206 响应头：之后的失败只能断开连接，不能换来源。
///
/// 由上游响应回调写、`streamRange` 的错误分支读；回调可能在别的线程执行，所以用原子量。
private final class LockedFlag: Sendable {
    private let storage = Atomic(false)

    var value: Bool { storage.load(ordering: .acquiring) }

    func set() {
        storage.store(true, ordering: .releasing)
    }
}

private func requireURL(_ value: String) throws -> URL {
    guard let url = URL(string: value) else {
        throw LoopbackPlaybackServerError.invalidRoute(value)
    }
    return url
}
