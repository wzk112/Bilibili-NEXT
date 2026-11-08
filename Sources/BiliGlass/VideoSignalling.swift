import BiliModels
import BiliNetworking
import Foundation

struct VideoSignalling: Sendable {
  var sampleType = ""
  var baseCodec: String?
  var transfer: Int?
  var dolbyProfile: Int?
  var dolbyLevel: Int?
  var compatibility: Int?
  var hevcSampleEntryOffsets: [Int] = []
  var hasHEVCParameterSets = false
  static func parse(_ data: Data) throws -> VideoSignalling {
    let b = Array(data)
    var result = VideoSignalling()
    func uint(_ p: Int, _ count: Int) -> UInt64 {
      b[p..<p + count].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    func string(_ p: Int, _ count: Int) -> String {
      String(bytes: b[p..<p + count], encoding: .ascii) ?? ""
    }
    func walk(_ start: Int, _ end: Int, _ depth: Int) throws {
      guard depth <= 12 else { throw BiliError(text: "媒体描述层级无效") }
      var p = start
      while p + 8 <= end {
        var size = Int(uint(p, 4))
        var header = 8
        let type = string(p + 4, 4)
        if size == 1 {
          guard p + 16 <= end, uint(p + 8, 8) <= UInt64(Int.max) else {
            throw BiliError(text: "媒体描述无效")
          }
          size = Int(uint(p + 8, 8))
          header = 16
        }
        if size == 0 { size = end - p }
        guard size >= header, size <= end - p else { throw BiliError(text: "媒体描述不完整") }
        let q = p + header
        let limit = p + size
        if ["moov", "trak", "mdia", "minf", "stbl", "sinf", "schi"].contains(type) {
          try walk(q, limit, depth + 1)
        } else if type == "stsd", q + 8 <= limit {
          try walk(q + 8, limit, depth + 1)
        } else if ["avc1", "hvc1", "hev1", "dvh1", "dvhe", "av01"].contains(type), q + 78 <= limit {
          result.sampleType = type
          if type == "hev1" { result.hevcSampleEntryOffsets.append(p + 4) }
          try walk(q + 78, limit, depth + 1)
        } else if type == "colr", q + 10 <= limit, ["nclx", "nclc"].contains(string(q, 4)) {
          result.transfer = Int(uint(q + 6, 2))
        } else if ["dvcC", "dvvC"].contains(type), q + 5 <= limit {
          result.dolbyProfile = Int(b[q + 2] >> 1)
          result.dolbyLevel = Int((b[q + 2] & 1) << 5 | b[q + 3] >> 3)
          result.compatibility = Int(b[q + 4] >> 4)
        } else if type == "hvcC", q + 13 <= limit {
          let byte = b[q + 1]
          let spaces = ["", "A", "B", "C"]
          let profile = byte & 31
          var bits = UInt32(uint(q + 2, 4))
          var reversed: UInt32 = 0
          for _ in 0..<32 {
            reversed = (reversed << 1) | (bits & 1)
            bits >>= 1
          }
          var constraints = Array(b[q + 6..<q + 12])
          while constraints.last == 0 { constraints.removeLast() }
          let c =
            constraints.isEmpty
            ? "0" : constraints.map { String(format: "%02X", $0) }.joined(separator: ".")
          result.baseCodec =
            "hvc1.\(spaces[Int(byte>>6)])\(profile).\(String(reversed,radix:16,uppercase:true)).\(byte&32 != 0 ? "H" : "L")\(b[q+12]).\(c)"
          if q + 23 <= limit {
            var cursor = q + 23
            var types = Set<Int>()
            for _ in 0..<Int(b[q + 22]) {
              guard cursor + 3 <= limit else { break }
              let nalType = Int(b[cursor] & 63)
              let count = Int(uint(cursor + 1, 2))
              cursor += 3
              var complete = count > 0
              for _ in 0..<count {
                guard cursor + 2 <= limit else { complete = false; break }
                let length = Int(uint(cursor, 2)); cursor += 2
                guard length > 0, length <= limit - cursor else { complete = false; break }
                cursor += length
              }
              if complete { types.insert(nalType) } else { break }
            }
            result.hasHEVCParameterSets = types.isSuperset(of: [32, 33, 34])
          }
        }
        p += size
      }
    }
    try walk(0, b.count, 0)
    return result
  }
  static func inspect(_ video: MediaRepresentation, client: HTTPRangeClient = HTTPRangeClient()) async throws -> (
    MediaRepresentation, VideoSignalling
  ) {
    let r = video.segmentBase.initialization
    guard r.endInclusive - r.start < 1024 * 1024 else { throw BiliError(text: "媒体描述过大") }
    let data = try await client.fetch(
      from: video.urlCandidates, range: HTTPByteRange(start: r.start, endInclusive: r.endInclusive),
      headers: API.mediaHeaders)
    let info = try parse(data.body)
    guard let attrs = video.videoAttributes else { return (video, info) }
    let metadataRange: VideoDynamicRange =
      info.transfer == 18 || (info.dolbyProfile == 8 && info.compatibility == 4)
      ? .hlg
      : info.transfer == 16 || info.dolbyProfile == 5
        || (info.dolbyProfile == 8 && info.compatibility == 1) ? .pq : attrs.dynamicRange
    #if os(macOS)
    // The quality ID is only a fallback. SDR-compatible Dolby base layers and
    // explicit SDR transfer functions must not inherit a PQ hint from playurl.
    let explicitHDR = info.transfer == 16 || info.transfer == 18 || info.dolbyProfile == 5
      || (info.dolbyProfile == 8 && [1, 4].contains(info.compatibility ?? -1))
    let explicitSDR = [1, 6, 7, 13, 14, 15].contains(info.transfer ?? -1)
      || (info.dolbyProfile == 8 && info.compatibility == 2)
    let range: VideoDynamicRange = !explicitHDR && explicitSDR ? .sdr : metadataRange
    #else
    let range = metadataRange
    #endif
    var codec = video.codecs
    var supplemental: String?
    if let base = info.baseCodec {
      if info.dolbyProfile == 5, let level = info.dolbyLevel {
        codec = String(format: "dvh1.05.%02d", level)
      } else {
        codec = base
        if info.dolbyProfile == 8, let level = info.dolbyLevel,
          let compatibility = info.compatibility, [1, 4].contains(compatibility)
        {
          supplemental =
            String(format: "dvh1.08.%02d", level) + (compatibility == 4 ? "/db4h" : "/db1p")
        }
      }
    }
    var initialization: Data?
    if info.hasHEVCParameterSets, !info.hevcSampleEntryOffsets.isEmpty {
      var compatible = data.body
      for offset in info.hevcSampleEntryOffsets { compatible.replaceSubrange(offset..<offset + 4, with: Data("hvc1".utf8)) }
      initialization = compatible
    }
    if info.dolbyProfile == 8, let compatibility = info.compatibility,
      [1, 4].contains(compatibility)
    {
      let brand = compatibility == 4 ? "db4h" : "db1p"
      var bytes = Array(initialization ?? data.body)
      var p = 0
      while p + 16 <= bytes.count {
        let size = bytes[p..<p + 4].reduce(0) { ($0 << 8) | Int($1) }
        guard size >= 8, size <= bytes.count - p else { break }
        if String(bytes: bytes[p + 4..<p + 8], encoding: .ascii) == "ftyp", size >= 20 {
          let brands = stride(from: p + 16, to: p + size, by: 4).compactMap { i in
            i + 4 <= p + size ? String(bytes: bytes[i..<i + 4], encoding: .ascii) : nil
          }
          if !brands.contains(brand) {
            let index = p + size - 4
            bytes.replaceSubrange(index..<index + 4, with: Array(brand.utf8))
            initialization = Data(bytes)
          }
          break
        }
        p += size
      }
    }
    let attributes = try VideoRepresentationAttributes(
      width: attrs.width, height: attrs.height, frameRate: attrs.frameRate, dynamicRange: range,
      supplementalCodecs: supplemental)
    return (
      MediaRepresentation(
        id: video.id, kind: video.kind, codecs: codec, mimeType: video.mimeType,
        bandwidth: video.bandwidth, videoAttributes: attributes, primaryURL: data.sourceURL,
        backupURLs: video.urlCandidates.filter { $0 != data.sourceURL },
        segmentBase: video.segmentBase, initializationOverride: initialization), info
    )
  }
}
