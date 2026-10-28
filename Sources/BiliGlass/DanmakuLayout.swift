import CoreGraphics
import Foundation

#if os(macOS)
  import AppKit
  private typealias DanmakuFont = NSFont
#else
  import UIKit
  private typealias DanmakuFont = UIFont
#endif

struct DanmakuPlacement: Sendable {
  let item: Danmaku
  let lane: Int
  let width: CGFloat
  let duration: Double
  let y: CGFloat
  let fontSize: CGFloat
  let height: CGFloat
  func x(at time: Double, viewportWidth: CGFloat) -> CGFloat {
    if [4, 5].contains(item.mode) { return (viewportWidth - width) / 2 }
    let progress = max(0, min(1, (time - item.time) / duration))
    return item.mode == 6 ? -width + (viewportWidth + width) * progress
      : viewportWidth - (viewportWidth + width) * progress
  }
}
struct DanmakuDisplayOptions: Sendable, Equatable {
  var scrolling = true
  var top = true
  var bottom = true
  var colored = true
  var avoidSubtitles = true
  var deduplicate = false
  var blockedWords: [String] = []
  var cloudRules: [DanmakuCloudRule] = []
  func accepts(_ item: Danmaku) -> Bool {
    guard (1...6).contains(item.mode), colored || item.color == 0xFFFFFF else { return false }
    guard
      !blockedWords.contains(where: {
        !$0.isEmpty && item.text.localizedCaseInsensitiveContains($0)
      })
    else { return false }
    guard
      !cloudRules.contains(where: { rule in
        switch rule.type {
        case 0:
          return !rule.filter.isEmpty && item.text.localizedCaseInsensitiveContains(rule.filter)
        case 1:
          return rule.filter.count <= 128 && item.text.count <= 1000
            && item.text.range(of: rule.filter, options: .regularExpression) != nil
        case 2: return item.senderHash == rule.filter
        default: return false
        }
      })
    else { return false }
    switch item.mode {
    case 4: return bottom
    case 5: return top
    default: return scrolling
    }
  }
  static func read(_ defaults: UserDefaults = .standard) -> Self {
    func flag(_ key: String, _ fallback: Bool) -> Bool {
      defaults.object(forKey: key) as? Bool ?? fallback
    }
    return Self(
      scrolling: flag("danmakuScrolling", true), top: flag("danmakuTop", true),
      bottom: flag("danmakuBottom", true), colored: flag("danmakuColored", true),
      avoidSubtitles: flag("danmakuAvoidSubtitles", true),
      deduplicate: flag("danmakuDeduplicate", false),
      blockedWords: (defaults.string(forKey: "danmakuBlockedWords") ?? "").split(separator: "\n")
        .map(String.init),
      cloudRules: defaults.data(forKey: "danmakuCloudRules").flatMap {
        try? JSONDecoder().decode([DanmakuCloudRule].self, from: $0)
      } ?? [])
  }
}
enum DanmakuLayout {
  static func mobileInsets(height: CGFloat, fullscreen: Bool) -> (top: CGFloat, bottom: CGFloat) {
    // Leave room for the top overlay controls without also reserving a large bottom toolbar inline.
    (min(fullscreen ? 56 : 44, height * 0.22), min(fullscreen ? 72 : 12, height * 0.20))
  }
  static func prepare(
    items: [Danmaku], size: CGSize, scale: CGFloat, area: CGFloat, duration: Double, time: Double,
    topInset: CGFloat = 12, bottomInset: CGFloat = 12, options: DanmakuDisplayOptions = .init(),
    retaining previous: [DanmakuPlacement] = []
  ) -> [DanmakuPlacement] {
    guard size.width > 0, size.height > topInset else { return [] }
    let scale = max(0.5, min(2, scale))
    let source = items.filter {
      $0.time >= max(0, time - 20) && $0.time <= time + 60 && options.accepts($0)
    }
    .sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    func fontSize(_ item: Danmaku) -> CGFloat {
      max(12, min(72, CGFloat(max(12, min(36, item.size))) * scale))
    }
    let largest = source.map(fontSize).max() ?? 25 * scale
    let font = DanmakuFont.systemFont(ofSize: largest, weight: .semibold)
    let rowHeight = ceil(max(38 * scale, font.ascender - font.descender + font.leading + 8))
    let bottom = max(bottomInset, options.avoidSubtitles ? size.height * 0.15 : 0)
    let usableHeight = max(0, size.height - bottom - topInset)
    let totalLanes = Int(usableHeight / rowHeight)
    guard totalLanes > 0 else { return [] }
    let lanes = max(1, min(totalLanes, Int(ceil(CGFloat(totalLanes) * max(0.2, min(1, area))))))
    var occupied = [[DanmakuPlacement]](repeating: [], count: totalLanes)
    let validIDs = Set(source.map(\.id))
    let running = previous.filter {
      $0.item.time <= time && time < $0.item.time + $0.duration && $0.lane < totalLanes
        && validIDs.contains($0.item.id)
    }
    var result = running
    var lastText: [String: Double] = [:]
    for placement in running {
      occupied[placement.lane].append(placement)
      lastText[placement.item.text] = placement.item.time
    }
    let runningIDs = Set(running.map { $0.item.id })
    for item in source {
      if runningIDs.contains(item.id) || (!previous.isEmpty && item.time < time) { continue }
      if options.deduplicate, let previous = lastText[item.text], item.time - previous < duration {
        continue
      }
      let pointSize = fontSize(item)
      let font = DanmakuFont.systemFont(ofSize: pointSize, weight: .semibold)
      let text = displayText(item.text)
      let width = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 8
      let height = ceil(font.ascender - font.descender + font.leading) + 4
      let rolling = ![4, 5].contains(item.mode)
      let life = rolling ? max(3, duration) : 4
      let candidates =
        item.mode == 4 ? Array((totalLanes - lanes..<totalLanes).reversed()) : Array(0..<lanes)
      if let lane = candidates.first(where: { lane in
        occupied[lane].removeAll { $0.item.time + $0.duration <= item.time }
        let y = topInset + CGFloat(lane) * rowHeight
        // A newly loaded larger font can change row spacing. Retained text keeps
        // its original coordinates, so reserve its actual vertical span as well.
        if running.contains(where: {
          $0.lane != lane && item.time < $0.item.time + $0.duration
            && $0.y < y + height && y < $0.y + $0.height
        }) { return false }
        return occupied[lane].allSatisfy { prior in
          guard rolling, ![4, 5].contains(prior.item.mode),
            (prior.item.mode == 6) == (item.mode == 6)
          else { return false }
          let elapsed = item.time - prior.item.time
          let velocity = (size.width + width) / life
          let oldVelocity = (size.width + prior.width) / prior.duration
          return oldVelocity * elapsed >= prior.width + 20
            && (velocity <= oldVelocity || velocity * (prior.duration - elapsed) <= size.width - 20)
        }
      }) {
        let placement = DanmakuPlacement(
          item: item, lane: lane, width: width, duration: life,
          y: topInset + CGFloat(lane) * rowHeight, fontSize: pointSize, height: height)
        occupied[lane].append(placement)
        result.append(placement)
        lastText[item.text] = item.time
      }
    }
    return result
  }
  static func displayText(_ raw: String) -> String {
    String(raw.prefix(1000)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(
      of: "\r", with: " ")
  }
}
