import AppKit
import SwiftUI
import Testing
@testable import BiliGlass

@Suite(.serialized) @MainActor struct PlaybackViewportLayoutTests {
  @Test func videoUsesAvailableSpaceWithoutClippingControls() async throws {
    _ = NSApplication.shared
    for size in [NSSize(width: 700, height: 600), NSSize(width: 1400, height: 900),
                 NSSize(width: 2000, height: 900)] {
      let frames = Frames()
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let host = NSHostingView(rootView: fixture(size: size, frames: frames))
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      for _ in 0..<50 where frames.values.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
      defer { window.close() }
      let title = try #require(frames.values[0])
      let video = try #require(frames.values[1])
      let controls = try #require(frames.values[2])
      #expect(abs(video.width / video.height - 16.0 / 9) < 0.001)
      #expect(video.minY >= title.maxY && controls.minY > video.maxY)
      #expect(controls.maxY <= size.height + 0.5)
      #expect(video.minX >= -0.5 && video.maxX <= size.width + 0.5)
      // Width or height must be exhausted; avoid retaining the old 1280-point cap.
      #expect(abs(video.width - size.width) < 0.5 || abs(controls.maxY - size.height) < 0.5)
      if size.width == 1400 { #expect(video.width > 1100) }
    }
  }

  private final class Frames { var values: [Int: CGRect] = [:] }
  private func fixture(size: NSSize, frames: Frames) -> some View {
    PlaybackViewportLayout(viewportHeight: size.height) {
      Text("Title").frame(height: 28)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.values[0] = $0 }
      Color.black
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.values[1] = $0 }
      Color.clear.frame(height: 180)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.values[2] = $0 }
    }.frame(width: size.width, height: size.height)
  }
}
