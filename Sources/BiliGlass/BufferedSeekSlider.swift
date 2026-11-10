import AppKit
import AVFoundation
import SwiftUI

/// Fractions of the playable timeline, independent of disk download byte counts.
struct PlaybackBufferRange: Equatable, Sendable {
  let start: Double
  var end: Double

  static func playable(_ ranges: [CMTimeRange], duration: Double) -> [Self] {
    guard duration.isFinite, duration > 0 else { return [] }
    let valid = ranges.compactMap { range -> Self? in
      let start = range.start.seconds, length = range.duration.seconds
      guard start.isFinite, length.isFinite, length > 0, (start + length).isFinite else { return nil }
      let lower = max(0, start), upper = min(duration, start + length)
      guard upper > lower else { return nil }
      return Self(start: lower / duration, end: upper / duration)
    }.sorted { $0.start < $1.start }
    var merged: [Self] = []
    for range in valid {
      if let last = merged.last, range.start <= last.end {
        merged[merged.count - 1].end = max(last.end, range.end)
      } else { merged.append(range) }
    }
    return merged
  }
}

struct BufferedSeekSlider: NSViewRepresentable {
  @Binding var value: Double
  let duration: Double
  let buffered: [PlaybackBufferRange]
  let enabled: Bool
  let onEditingChanged: (Bool) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> SeekSlider {
    let slider = SeekSlider()
    slider.cell = BufferedSliderCell()
    slider.isContinuous = true
    slider.target = context.coordinator
    slider.action = #selector(Coordinator.changed(_:))
    slider.setAccessibilityLabel("播放进度")
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return slider
  }
  func updateNSView(_ slider: SeekSlider, context: Context) {
    context.coordinator.parent = self
    slider.minValue = 0; slider.maxValue = max(1, duration)
    if !slider.tracking { slider.doubleValue = min(slider.maxValue, max(0, value)) }
    slider.isEnabled = enabled
    slider.editing = onEditingChanged
    (slider.cell as? BufferedSliderCell)?.buffered = buffered
    slider.setAccessibilityValueDescription("\(Int(max(0, value))) 秒，共 \(Int(max(0, duration))) 秒")
    slider.needsDisplay = true
  }
  @MainActor final class Coordinator: NSObject {
    var parent: BufferedSeekSlider
    init(_ parent: BufferedSeekSlider) { self.parent = parent }
    @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
  }
}

final class SeekSlider: NSSlider {
  var editing: ((Bool) -> Void)?
  private(set) var tracking = false
  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    tracking = true; editing?(true)
    super.mouseDown(with: event)
    tracking = false; editing?(false)
  }
}

final class BufferedSliderCell: NSSliderCell {
  var buffered: [PlaybackBufferRange] = []
  override func drawBar(inside rect: NSRect, flipped: Bool) {
    let bar = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
    func fill(_ color: NSColor, from start: Double = 0, to end: Double = 1) {
      guard end > start else { return }
      color.setFill()
      NSBezierPath(roundedRect: NSRect(x: bar.minX + bar.width * start, y: bar.minY,
        width: bar.width * (end - start), height: bar.height), xRadius: 2, yRadius: 2).fill()
    }
    fill(.white.withAlphaComponent(isEnabled ? 0.18 : 0.08))
    for range in buffered { fill(.white.withAlphaComponent(0.5), from: range.start, to: range.end) }
    let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
    fill(NSColor(red: 0.86, green: 0.24, blue: 0.43, alpha: isEnabled ? 1 : 0.3), to: fraction)
  }
}
