import BiliModels
import BiliNetworking
import Foundation
import Testing
@testable import BiliGlass

private struct ColorMetadataStream: HTTPRangeStreaming {
  let bytes: Data
  func stream(from url: URL, rangeHeader: String, expectedRange r: HTTPByteRange,
    expectedCompleteLength: Int64?, headers: [String: String], allowedContentTypes: Set<String>?,
    requiresContentLength: Bool, onResponse: @escaping @Sendable (HTTPRangeStreamResponse) async throws -> Void,
    onChunk: @escaping @Sendable (Data) async throws -> Void) async throws -> HTTPRangeStreamResult {
    try await onResponse(HTTPRangeStreamResponse(contentRange: HTTPContentRange(start: r.start,
      endInclusive: r.endInclusive, completeLength: Int64(bytes.count)), contentLength: r.length, contentType: "video/mp4"))
    try await onChunk(bytes.subdata(in: Int(r.start)..<Int(r.endInclusive + 1)))
    return HTTPRangeStreamResult(byteCount: r.length)
  }
}

struct MacDynamicRangeTests {
  private func box(_ type: String, _ payload: Data) -> Data {
    var size = UInt32(payload.count + 8).bigEndian
    return withUnsafeBytes(of: &size) { Data($0) } + Data(type.utf8) + payload
  }
  private func inspect(quality: Int, transfer: UInt8, profile: UInt8? = nil, compatibility: UInt8 = 0) async throws -> MediaRepresentation {
    let color = box("colr", Data("nclx".utf8) + Data([0, 1, 0, transfer, 0, 1, 0]))
    let dolby = profile.map { box("dvvC", Data([1, 0, $0 << 1, 8 << 3, compatibility << 4])) } ?? Data()
    let entry = box("hvc1", Data(repeating: 0, count: 78) + color + dolby)
    let bytes = box("moov", box("stsd", Data([0, 0, 0, 0, 0, 0, 0, 1]) + entry))
    let attributes = try VideoRepresentationAttributes(width: 1920, height: 1080, frameRate: 30, dynamicRange: .pq)
    let video = try MediaRepresentation(id: quality, kind: .video, codecs: "hvc1.1.6.L120.90", mimeType: "video/mp4",
      videoAttributes: attributes, primaryURL: URL(string: "https://fixture.test/video.mp4")!, backupURLs: [],
      segmentBase: SegmentBase(initialization: MediaByteRange(start: 0, endInclusive: Int64(bytes.count - 1)),
        index: MediaByteRange(start: Int64(bytes.count), endInclusive: Int64(bytes.count + 1))))
    return try await VideoSignalling.inspect(video, client: HTTPRangeClient(streamer: ColorMetadataStream(bytes: bytes))).0
  }

  @Test(arguments: [125, 126], [UInt8(1), 16, 18])
  func realTransferFunctionOverridesQualityNumber(quality: Int, transfer: UInt8) async throws {
    let video = try await inspect(quality: quality, transfer: transfer)
    let expected: VideoDynamicRange = transfer == 16 ? .pq : transfer == 18 ? .hlg : .sdr
    #expect(video.videoAttributes?.dynamicRange == expected)
  }

  @Test func dolbyProfilesKeepTheirActualBaseLayerRange() async throws {
    #expect(try await inspect(quality: 126, transfer: 1, profile: 5).videoAttributes?.dynamicRange == .pq)
    #expect(try await inspect(quality: 126, transfer: 1, profile: 8, compatibility: 1).videoAttributes?.dynamicRange == .pq)
    #expect(try await inspect(quality: 126, transfer: 1, profile: 8, compatibility: 4).videoAttributes?.dynamicRange == .hlg)
    #expect(try await inspect(quality: 126, transfer: 1, profile: 8, compatibility: 2).videoAttributes?.dynamicRange == .sdr)
  }
}
