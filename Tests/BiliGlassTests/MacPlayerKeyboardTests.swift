import AVKit
import Testing
@testable import BiliGlass

private final class KeyboardTestWindow: NSWindow {
  override var isKeyWindow: Bool { true }
}

@MainActor struct MacPlayerKeyboardTests {
  private func item() -> AVPlayerItem {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return AVPlayerItem(url: root.appendingPathComponent("Vendor/BiliKitCore/Tests/BiliPlaybackTests/Fixtures/video-avc.mp4"))
  }
  private func key(_ text: String, code: UInt16, window: NSWindow,
                   modifiers: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text,
      charactersIgnoringModifiers: text, isARepeat: repeated, keyCode: code))
  }

  @Test func speedVolumeAndMuteKeysWorkWithoutStartingPausedPlayback() throws {
    _ = NSApplication.shared
    let window = KeyboardTestWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: .borderless, backing: .buffered, defer: false)
    let view = NativeVideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    window.contentView = view
    let playback = Playback()
    playback.nativeView = view
    view.handlesPlaybackShortcuts = true
    playback.player.replaceCurrentItem(with: item())
    let keyboard = PlayerKeyboard(view: view, playback: playback)
    defer { keyboard.stop(); playback.stop(); window.orderOut(nil) }
    #expect(keyboard.handle(try key("]", code: 30, window: window)) == nil)
    #expect(playback.speed == 1.25)
    #expect(playback.feedback.notice?.symbol == "speedometer")
    #expect(keyboard.handle(try key("[", code: 33, window: window)) == nil)
    #expect(playback.speed == 1)
    playback.setSpeed(2)
    #expect(keyboard.handle(try key("\\", code: 42, window: window)) == nil)
    #expect(playback.speed == 1)
    playback.player.volume = 0.5
    #expect(keyboard.handle(try key("", code: 126, window: window)) == nil)
    #expect(abs(playback.player.volume - 0.55) < 0.001)
    #expect(abs(playback.volume - 0.55) < 0.001)
    #expect(playback.feedback.notice?.title == "音量 55%")
    #expect(keyboard.handle(try key("", code: 125, window: window)) == nil)
    #expect(abs(playback.player.volume - 0.5) < 0.001)
    #expect(keyboard.handle(try key("m", code: 46, window: window)) == nil)
    #expect(playback.player.isMuted)
    #expect(playback.muted)
    #expect(playback.feedback.notice?.title == "已静音")
    _ = keyboard.handle(try key("m", code: 46, window: window, repeated: true))
    #expect(playback.player.isMuted)
    playback.setVolume(0.5)
    #expect(!playback.muted && !playback.player.isMuted)
    #expect(playback.player.rate == 0)
    playback.setSpeed(2)
    _ = keyboard.handle(try key("]", code: 30, window: window))
    #expect(playback.speed == 2)
    playback.setSpeed(0.5)
    _ = keyboard.handle(try key("[", code: 33, window: window))
    #expect(playback.speed == 0.5)
    playback.player.volume = 0
    _ = keyboard.handle(try key("", code: 125, window: window))
    #expect(playback.player.volume == 0)
    var danmakuToggles = 0
    view.toggleDanmaku = { danmakuToggles += 1 }
    _ = keyboard.handle(try key("d", code: 2, window: window))
    _ = keyboard.handle(try key("d", code: 2, window: window, repeated: true))
    #expect(danmakuToggles == 1)
  }

  @Test func editableTextAndCommandShortcutsKeepTheirEvents() throws {
    _ = NSApplication.shared
    let window = KeyboardTestWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: .borderless, backing: .buffered, defer: false)
    let view = NativeVideoView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
    window.contentView = view
    let playback = Playback()
    playback.nativeView = view; view.handlesPlaybackShortcuts = true
    playback.player.replaceCurrentItem(with: item())
    let keyboard = PlayerKeyboard(view: view, playback: playback)
    defer { keyboard.stop(); playback.stop(); window.orderOut(nil) }
    let editor = NSTextView(frame: .zero)
    view.addSubview(editor)
    #expect(window.makeFirstResponder(editor))
    let typed = try key("]", code: 30, window: window)
    #expect(keyboard.handle(typed) === typed)
    #expect(playback.speed == 1)
    _ = window.makeFirstResponder(view)
    let command = try key("m", code: 46, window: window, modifiers: .command)
    #expect(keyboard.handle(command) === command)
    #expect(!playback.player.isMuted)
    #expect(playback.feedback.notice == nil)
  }
}
