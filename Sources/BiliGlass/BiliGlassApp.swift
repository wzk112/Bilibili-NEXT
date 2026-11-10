import SwiftUI

final class AppLifecycle: NSObject, NSApplicationDelegate {
  private var memoryPressure: DispatchSourceMemoryPressure?
  func applicationDidFinishLaunching(_ notification: Notification) {
    MacUpdater.shared.start()
    PlaybackTemporaryFiles.cleanup()
    // Explicitly load the current resource for the running Dock tile; older
    // locally replaced bundles may still have a cached LaunchServices icon.
    if let iconURL = Bundle.main.url(forResource: "AppIcon-Flat", withExtension: "icns") {
      NSApp.applicationIconImage = NSImage(contentsOf: iconURL)
    }
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler {
      Task {
        await ThumbnailCache.shared.trimMemory()
        await BackgroundImages.shared.trimMemory()
        await PreviewSheets.shared.trimMemory()
      }
    }
    source.resume(); memoryPressure = source
  }
  func applicationWillTerminate(_ notification: Notification) { PlaybackTemporaryFiles.cleanup(staleOnly: false) }
}

@main struct BiliGlassApp: App {
  @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
  @State private var store = Store()
  var body: some Scene {
    Window("Bilibili NEXT", id: "main") { RootView(store: store) }.defaultSize(width: 1260, height: 840)
      .windowStyle(.hiddenTitleBar)
      .commands {
        CommandGroup(after: .appInfo) {
          Button("检查更新…") { MacUpdater.shared.check(presentResult: true) }
            .disabled(MacUpdater.shared.checking)
        }
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .help) {
          Button("使用指南") { store.guide.show(.tutorial) }
          Button("更新说明") { store.guide.show(.update(previous: nil)) }
        }
        CommandGroup(after: .toolbar) {
          Button("搜索") {
            store.searchFocus += 1
          }.keyboardShortcut("f")
          Button("切换全屏播放") { store.fullscreen.toggle(store: store) }
            .keyboardShortcut("f", modifiers: [.command, .control]).disabled(!store.showPlayer)
          Button("刷新") {
            if store.showPlayer { store.playback.retry(api: store.api) } else { store.reload() }
          }.keyboardShortcut("r")
        }
      }
    Settings { PreferencesView(store: store) }
  }
}
