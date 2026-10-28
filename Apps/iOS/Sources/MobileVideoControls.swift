import AVKit
import SwiftUI

/// Inline and fullscreen use the same controls and long-press surface.
struct MobileVideoPlayer: View {
  @Environment(\.columnNavigation) private var columns
  @Bindable var store: Store
  @State private var fullscreen = false
  @State private var automaticFullscreen = false
  @State private var onScreen = false
  @State private var checkedInitialOrientation = false
  @State private var suppressAutomaticFullscreen = false
  var body: some View {
    ZStack {
      if fullscreen { Color.black }
      else { MobileVideoSurface(store: store, fullscreen: false) { fullscreen = true } }
    }
    .onAppear {
      onScreen = true
    }
    .onDisappear { onScreen = false }
    .task {
      guard UIDevice.current.userInterfaceIdiom == .phone, !columns, !checkedInitialOrientation else { return }
      checkedInitialOrientation = true
      // Let the presenting player finish its transition before opening another cover.
      do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      if onScreen && store.showPlayer && !fullscreen && !suppressAutomaticFullscreen
        && scene?.effectiveGeometry.interfaceOrientation.isLandscape == true {
        automaticFullscreen = true
        fullscreen = true
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      // iPad rotation and multitasking resize the inline player; fullscreen is explicit.
      guard UIDevice.current.userInterfaceIdiom == .phone, !columns else { return }
      let orientation = UIDevice.current.orientation
      store.orientationDiagnostics = ["device": String(orientation.rawValue), "onScreen": String(onScreen), "showPlayer": String(store.showPlayer)]
      if orientation.isPortrait {
        suppressAutomaticFullscreen = false
        if automaticFullscreen { fullscreen = false; automaticFullscreen = false }
      } else if orientation.isLandscape && store.showPlayer && onScreen
        && !fullscreen && !suppressAutomaticFullscreen {
        automaticFullscreen = true
        fullscreen = true
      }
    }
    .fullScreenCover(isPresented: $fullscreen, onDismiss: { store.playback.endTemporarySpeed() }) {
      GeometryReader { geometry in
      MobileVideoSurface(store: store, fullscreen: true) {
        fullscreen = false
        automaticFullscreen = false
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        suppressAutomaticFullscreen = scene?.effectiveGeometry.interfaceOrientation.isLandscape == true
      }.frame(width: geometry.size.width, height: geometry.size.height)
      }.background(Color.black.ignoresSafeArea()).statusBarHidden()
    }
  }
}

struct MobileVideoSurface: View {
  @Bindable var store: Store
  let fullscreen: Bool
  var toggleFullscreen: () -> Void
  private var pip: MobilePiPSession { store.mobilePiP }
  @State private var visible = true
  @State private var position = 0.0
  @State private var seeking = false
  @State private var settings = false
  @AppStorage("danmakuEnabled") private var danmaku = true
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    ZStack {
      MobileNativePlayer(store: store, pip: pip, fullscreen: fullscreen)
        .ignoresSafeArea(edges: fullscreen ? .all : [])
        .onTapGesture { visible.toggle() }
      if visible {
        VStack(spacing: 0) {
          LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: fullscreen ? 100 : 64)
          Spacer(minLength: 0)
          LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            .frame(height: fullscreen ? 130 : 64)
        }.ignoresSafeArea(edges: fullscreen ? .all : []).allowsHitTesting(false)
        VStack(spacing: 0) {
          HStack(spacing: fullscreen ? 24 : 16) {
            Menu {
              if let streams = store.playback.streams {
                ForEach(Array(Set(streams.videos.map(\.id))).sorted(by: >), id: \.self) { quality in
                  Button(streams.names[quality] ?? String(quality)) { store.playback.selectQuality(quality, api: store.api) }
                }
              } else { Text("播放地址准备中") }
            } label: {
              Text(store.playback.streams?.names[store.playback.selectedQuality] ?? "清晰度").lineLimit(1)
            }.accessibilityLabel("清晰度")
            Button { danmaku.toggle() } label: {
              Image(systemName: danmaku ? "text.bubble.fill" : "text.bubble").frame(width: 44, height: 44).contentShape(.rect)
            }.accessibilityLabel(danmaku ? "关闭弹幕" : "开启弹幕")
            Menu {
              ForEach([0.5, 0.75, 1, 1.25, 1.5, 2, 3], id: \.self) { speed in
                Button("\(speed.formatted())×") { store.playback.setSpeed(Float(speed)) }
              }
            } label: { Text("\(Double(store.playback.speed).formatted())×") }.accessibilityLabel("倍速")
            Spacer(minLength: 0)
            Menu {
              Button("关闭字幕") { Task { await store.extras.selectSubtitle("", api: store.api) } }
              ForEach(store.extras.subtitles) { track in
                Button(track.title) { Task { await store.extras.selectSubtitle(track.id, api: store.api) } }
              }
              ForEach(store.extras.chapters) { chapter in
                Button(chapter.title) { store.playback.seek(to: chapter.start) }
              }
              Button("弹幕设置") { settings = true }
              Button("画中画") { pip.toggle() }.disabled(pip.controller?.isPictureInPicturePossible != true)
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(.rect) }.accessibilityLabel("播放器设置")
          }.frame(minHeight: 44).padding(.horizontal, 12)
          Spacer(minLength: 0)
          if fullscreen {
            HStack {
              Text(store.playback.detail?.video.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
              Spacer()
            }.padding(.horizontal, 16).padding(.bottom, 4)
          }
          HStack(spacing: 12) {
            Button { store.playback.togglePlayback() } label: {
              Image(systemName: store.playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44).contentShape(.rect)
            }.accessibilityLabel("播放或暂停")
              .accessibilityValue(store.playback.isPlaying ? "正在播放" : "已暂停")
              .accessibilityIdentifier("player-play-pause")
            Text(clock(seeking ? position : store.playback.positionSeconds)).font(.caption.monospacedDigit())
            Slider(value: $position, in: 0...max(1, store.playback.durationSeconds), onEditingChanged: { editing in
              seeking = editing
              if !editing { store.playback.seek(to: position) }
            }).accessibilityLabel("播放进度")
            Text(clock(store.playback.durationSeconds)).font(.caption.monospacedDigit())
            Button(action: toggleFullscreen) {
              Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44).contentShape(.rect)
            }.accessibilityLabel(fullscreen ? "退出全屏" : "全屏")
              .accessibilityIdentifier("player-fullscreen-toggle")
          }.frame(minHeight: 44).padding(.horizontal, 12)
        }.padding(.horizontal, fullscreen ? 16 : 0).padding(.vertical, fullscreen ? 8 : 0)
          // Keep transport controls usable in narrow windows at accessibility text sizes.
          .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          .font(.subheadline.weight(.medium)).buttonStyle(.plain).foregroundStyle(.white).tint(.white)
      }
      if store.playback.loading || store.playback.buffering {
        ProgressView(store.playback.loading ? store.playback.loadingMessage : "正在缓冲…")
          .font(.caption).tint(.white).foregroundStyle(.white).allowsHitTesting(false)
      }
      if let error = store.playback.error {
        VStack(spacing: 8) {
          Text(error).font(.caption).lineLimit(3)
          Button("重试播放") { store.playback.retry(api: store.api) }
        }.padding(12).foregroundStyle(.white).background(.black.opacity(0.8), in: .rect(cornerRadius: 8))
          .padding(.horizontal, 24).padding(.vertical, 50)
      }
    }.background(.black)
      .onChange(of: store.playback.positionSeconds, initial: true) { if !seeking { position = min(max(0, store.playback.positionSeconds), max(1, store.playback.durationSeconds)) } }
      .onChange(of: scenePhase) { if scenePhase != .active { store.playback.endTemporarySpeed() } }
      .sheet(isPresented: $settings) { MobileDanmakuSettings() }
  }
}
