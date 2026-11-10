import BiliModels
import BiliNetworking
import Foundation
import Testing
@testable import BiliGlass

private actor CDNFixture: HTTPRangeStreaming {
  struct Plan: Sendable {
    var headerDelay: Duration = .zero
    var bodyDelay: Duration = .zero
    var invalid = false
    var truncated = false
    var chunks = 1
  }
  let plans: [String: Plan]
  var calls: [(String, HTTPByteRange)] = []
  var active = 0
  var peak = 0
  init(_ plans: [String: Plan]) { self.plans = plans }
  func stream(
    from url: URL, rangeHeader: String, expectedRange: HTTPByteRange,
    expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
    requiresContentLength: Bool,
    onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
    onChunk: @escaping @Sendable (Data) async throws -> Void
  ) async throws -> HTTPRangeStreamResult {
    let host = url.host!
    let plan = plans[host] ?? Plan()
    calls.append((host, expectedRange)); active += 1; peak = max(peak, active)
    defer { active -= 1 }
    try await Task.sleep(for: plan.headerDelay)
    if plan.invalid { throw HTTPRangeResponseError.rejectedBody }
    try await onResponse(HTTPRangeStreamResponse(
      contentRange: HTTPContentRange(start: expectedRange.start, endInclusive: expectedRange.endInclusive,
                                     completeLength: expectedCompleteLength ?? 1_000_000),
      contentLength: expectedRange.length, contentType: "video/mp4"))
    let count = Int(expectedRange.length) - (plan.truncated ? 1 : 0)
    let step = max(1, count / plan.chunks)
    for start in stride(from: 0, to: count, by: step) {
      try await Task.sleep(for: plan.bodyDelay)
      try await onChunk(Data((start..<min(count, start + step)).map { UInt8((Int(expectedRange.start) + $0) % 251) }))
    }
    return HTTPRangeStreamResult(byteCount: UInt64(count))
  }
}
private actor CDNOutput {
  var data = Data()
  var response: HTTPRangeStreamResponse?
  var headers = 0
  func append(_ value: Data) { data.append(value) }
  func header(_ value: HTTPRangeStreamResponse) { response = value; headers += 1 }
}

private actor BrokenNodeFixture: HTTPRangeStreaming {
  let mismatchedBackup: Bool
  var calls: [(String, HTTPByteRange)] = []
  init(mismatchedBackup: Bool = false) { self.mismatchedBackup = mismatchedBackup }
  func stream(from url: URL, rangeHeader: String, expectedRange r: HTTPByteRange,
    expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
    requiresContentLength: Bool, onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
    onChunk: @escaping @Sendable (Data) async throws -> Void) async throws -> HTTPRangeStreamResult {
    let backup = url.host == "backup.test"
    calls.append((url.host!, r))
    if backup { try await Task.sleep(for: .milliseconds(20)) }
    try await onResponse(HTTPRangeStreamResponse(contentRange: HTTPContentRange(start: r.start,
      endInclusive: r.endInclusive, completeLength: 1_000_000), contentLength: r.length, contentType: "video/mp4"))
    let interrupted = !backup && r.start >= 512 && r.start < 2048
    let count = interrupted ? min(23, Int(r.length)) : Int(r.length)
    try await onChunk(Data((0..<count).map { UInt8((Int(r.start) + $0 + (backup && mismatchedBackup ? 1 : 0)) % 251) }))
    if interrupted { throw HTTPRangeResponseError.transport(errorType: "NSURLError(-1005)") }
    return HTTPRangeStreamResult(byteCount: r.length)
  }
}

@Suite struct CDNSelectionTests {
  @Test func brokenNodeIsRepairedFromVerifiedBackupWithoutRepeatingPrefix() async throws {
    let fixture = BrokenNodeFixture()
    let transport = CDNTransport(source: fixture, health: CDNHealth())
    let choice = try await transport.select(representation(["primary.test", "backup.test"]), headers: [:])
    let output = CDNOutput()
    try await read(transport, url: choice.representation.primaryURL, output: output, start: 1024, end: 2047)
    #expect(await output.data == Data((1024...2047).map { UInt8($0 % 251) }))
    #expect(await output.headers == 1)
    #expect(await fixture.calls.contains { $0.0 == "backup.test" && $0.1.start == 1047 && $0.1.endInclusive == 2047 })
    #expect(await transport.activeHosts()["videoHost"] == "backup.test")
    let next = CDNOutput()
    try await read(transport, url: choice.representation.primaryURL, output: next, start: 4096, end: 8191)
    #expect(await next.data == Data((4096...8191).map { UInt8($0 % 251) }))
    #expect(await transport.activeHosts()["videoHost"] == "backup.test")
    #expect(await transport.activeHosts()["videoSwitches"] == "1")
  }
  @Test func backupWithDifferentMediaIsRejectedBeforeAnyBytesAreSpliced() async throws {
    let fixture = BrokenNodeFixture(mismatchedBackup: true)
    let transport = CDNTransport(source: fixture, health: CDNHealth())
    let choice = try await transport.select(representation(["primary.test", "backup.test"]), headers: [:])
    let output = CDNOutput()
    await #expect(throws: (any Error).self) {
      try await read(transport, url: choice.representation.primaryURL, output: output, start: 1024, end: 2047)
    }
    #expect(await output.data.count == 23)
    #expect(await fixture.calls.allSatisfy { $0.0 != "backup.test" || $0.1.start == 0 })
  }
  private func representation(_ hosts: [String], end: Int64 = 511) throws -> MediaRepresentation {
    let urls = hosts.map { URL(string: "https://\($0)/media.m4s?token=fresh")! }
    return try MediaRepresentation(id: 80, kind: .video, codecs: "avc1", mimeType: "video/mp4",
      primaryURL: urls[0], backupURLs: Array(urls.dropFirst()),
      segmentBase: SegmentBase(initialization: MediaByteRange(start: 0, endInclusive: 127),
                               index: MediaByteRange(start: 128, endInclusive: end)))
  }
  private func read(_ transport: CDNTransport, url: URL, output: CDNOutput,
                    start: Int64 = 0, end: Int64 = 15, total: Int64? = nil,
                    consumerDelay: Duration = .zero) async throws {
    let range = try HTTPByteRange(start: start, endInclusive: end)
    _ = try await transport.stream(from: url, rangeHeader: range.headerValue, expectedRange: range,
      expectedCompleteLength: total, headers: [:], allowedContentTypes: ["video/mp4"],
      requiresContentLength: true, onResponse: { await output.header($0) }, onChunk: {
        try await Task.sleep(for: consumerDelay)
        await output.append($0)
      })
  }
  @Test func backupWinsWithoutWaitingForUnresponsivePrimary() async throws {
    let fixture = CDNFixture(["slow.test": .init(bodyDelay: .seconds(30)),
                              "fast.test": .init(bodyDelay: .milliseconds(20))])
    let transport = CDNTransport(source: fixture, health: CDNHealth())
    let start = ContinuousClock.now
    let selection = try await transport.select(representation(["slow.test", "fast.test"]), headers: [:])
    #expect(selection.host == "fast.test")
    #expect(selection.representation.backupURLs.isEmpty)
    #expect(selection.candidateCount == 2)
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(await fixture.active == 0)
    #expect(await fixture.peak == 2)
  }
  @Test func headersAloneAndTruncatedBodiesCannotWin() async throws {
    let fixture = CDNFixture(["header.test": .init(bodyDelay: .seconds(20)),
      "truncated.test": .init(truncated: true), "valid.test": .init(bodyDelay: .milliseconds(20))])
    let transport = CDNTransport(source: fixture, health: CDNHealth())
    let choice = try await transport.select(representation(["header.test", "truncated.test", "valid.test"]), headers: [:])
    #expect(choice.host == "valid.test")
    #expect(await fixture.active == 0)
  }
  @Test func probesAreBoundedAndOnlyAPIProvidedCandidatesAreUsed() async throws {
    let fixture = CDNFixture([:])
    let transport = CDNTransport(source: fixture, health: CDNHealth())
    let choice = try await transport.select(representation(["a.test", "b.test", "c.test", "d.test"], end: 200_000), headers: [:])
    #expect(choice.candidateCount == 3)
    let calls = await fixture.calls
    #expect(calls.count <= 3)
    #expect(calls.allSatisfy { $0.1.length <= 65_536 && $0.0 != "d.test" })
  }
  @Test func selectedPrefixIsReusedForInitAndIndexWithExactRangeValidation() async throws {
    let fixture = CDNFixture([:])
    let transport = CDNTransport(source: fixture, health: CDNHealth())
    let choice = try await transport.select(representation(["a.test"]), headers: [:])
    let output = CDNOutput()
    try await read(transport, url: choice.representation.primaryURL, output: output, start: 128, end: 255, total: 1_000_000)
    #expect(await output.data == Data((128...255).map { UInt8($0 % 251) }))
    #expect(await output.response?.contentLength == 128)
    #expect(await output.response?.contentRange.start == 128)
    #expect(await fixture.calls.count == 1)
    await #expect(throws: (any Error).self) {
      try await read(transport, url: choice.representation.primaryURL, output: CDNOutput(), total: 900_000)
    }
    #expect(await fixture.calls.count == 1)
  }
  @Test func allSlowSourcesFailWithinProbeBudget() async throws {
    let fixture = CDNFixture(["a.test": .init(bodyDelay: .seconds(30)), "b.test": .init(bodyDelay: .seconds(30))])
    let transport = CDNTransport(source: fixture, health: CDNHealth(), probeTimeout: 0.06)
    let start = ContinuousClock.now
    await #expect(throws: (any Error).self) {
      _ = try await transport.select(representation(["a.test", "b.test"]), headers: [:])
    }
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(await fixture.active == 0)
  }
  @Test func slowerProxiedCDNCanStillWinStartup() async throws {
    let fixture = CDNFixture(["proxy.test": .init(headerDelay: .milliseconds(300))])
    let transport = CDNTransport(source: fixture, health: CDNHealth(), probeTimeout: 0.06,
      usesSystemProxy: { _ in true })
    let selection = try await transport.select(representation(["proxy.test"]), headers: [:])
    #expect(selection.host == "proxy.test")
    #expect(await fixture.active == 0)
  }
  @Test func cancellationStopsProbesAndDoesNotQuarantineHosts() async throws {
    let fixture = CDNFixture(["a.test": .init(bodyDelay: .seconds(30)), "b.test": .init(bodyDelay: .seconds(30))])
    let health = CDNHealth()
    let transport = CDNTransport(source: fixture, health: health)
    let rep = try representation(["a.test", "b.test"])
    let task = Task { try await transport.select(rep, headers: [:]) }
    try await Task.sleep(for: .milliseconds(25))
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(await fixture.active == 0)
    #expect(await health.candidates(rep.urlCandidates) == rep.urlCandidates)
  }
  @Test func consumerBackpressureDoesNotTriggerNetworkTimeout() async throws {
    let fixture = CDNFixture([:])
    let transport = CDNTransport(source: fixture, health: CDNHealth(), idleTimeout: .milliseconds(40), rangeTimeout: .milliseconds(40))
    let output = CDNOutput()
    try await read(transport, url: URL(string: "https://a.test/media")!, output: output,
                   consumerDelay: .milliseconds(150))
    #expect(await output.data.count == 16)
  }
  @Test func boundedPieceHasATimeBudgetEvenBeforeTheIdleDeadline() async throws {
    let fixture = CDNFixture(["a.test": .init(bodyDelay: .seconds(30))])
    let transport = CDNTransport(source: fixture, health: CDNHealth(), idleTimeout: .seconds(8), rangeTimeout: .milliseconds(40))
    let start = ContinuousClock.now
    await #expect(throws: CDNIdleTimeout.self) {
      try await read(transport, url: URL(string: "https://a.test/media")!, output: CDNOutput())
    }
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(await fixture.active == 0)
  }
  @Test func progressingParallelBlockIsNotAbandonedAtTheOldTotalDeadline() async throws {
    let fixture = CDNFixture(["a.test": .init(bodyDelay: .milliseconds(40), chunks: 8)])
    let transport = CDNTransport(source: fixture, health: CDNHealth(), idleTimeout: .milliseconds(200), rangeTimeout: .milliseconds(150))
    let output = CDNOutput()
    try await read(transport, url: URL(string: "https://a.test/media")!, output: output)
    #expect(await output.data.count == 16)
    #expect(await transport.diagnostics().isEmpty)
  }
  @Test func queuedFirstResponseIsNotMistakenForAnIdleBody() async throws {
    let fixture = CDNFixture(["a.test": .init(headerDelay: .milliseconds(150))])
    let transport = CDNTransport(source: fixture, health: CDNHealth(), idleTimeout: .milliseconds(40))
    let output = CDNOutput()
    try await read(transport, url: URL(string: "https://a.test/media")!, output: output)
    #expect(await output.data.count == 16)
  }
  @Test func idleBodyTimesOutAndNextSelectionAvoidsFailedHost() async throws {
    let fixture = CDNFixture(["a.test": .init(bodyDelay: .seconds(30))])
    let health = CDNHealth()
    let transport = CDNTransport(source: fixture, health: health, idleTimeout: .milliseconds(40))
    await #expect(throws: (any Error).self) {
      try await read(transport, url: URL(string: "https://a.test/media")!, output: CDNOutput())
    }
    #expect(await fixture.active == 0)
    let choice = try await transport.select(representation(["a.test", "b.test"]), headers: [:])
    #expect(choice.host == "b.test")
    #expect(choice.candidateCount == 1)
  }
  @Test func freshURLDoesNotReuseOldSignedURLCache() async throws {
    let fixture = CDNFixture([:])
    let transport = CDNTransport(source: fixture, health: CDNHealth())
    _ = try await transport.select(representation(["a.test"]), headers: [:])
    try await read(transport, url: URL(string: "https://a.test/media.m4s?token=refreshed")!, output: CDNOutput())
    #expect(await fixture.calls.count == 2)
  }
}
