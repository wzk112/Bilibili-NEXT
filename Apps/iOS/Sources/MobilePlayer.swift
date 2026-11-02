import AVKit
import SwiftUI
import UIKit

@MainActor @Observable final class MobilePiPSession {
  var controller: AVPictureInPictureController?
  var pendingController: AVPictureInPictureController?
  var retainedHost: UIViewController?
  var retainedDelegate: NSObject?
  func bind(_ next: AVPictureInPictureController) {
    if controller?.isPictureInPictureActive == true { pendingController = next }
    else { controller = next }
  }
  func stopped() {
    retainedHost = nil
    retainedDelegate = nil
    if let pendingController { controller = pendingController; self.pendingController = nil }
  }
  func toggle() {
    guard let controller else { return }
    if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
    else { controller.startPictureInPicture() }
  }
}

struct MobileNativePlayer: UIViewControllerRepresentable {
  @Bindable var store: Store
  var pip: MobilePiPSession? = nil
  var fullscreen = false
  var onSwipeDown: (() -> Void)? = nil
  @AppStorage("danmakuEnabled") private var enabled = true
  @AppStorage("danmakuOpacity") private var opacity = 0.85
  @AppStorage("danmakuScale") private var scale = 1.0
  @AppStorage("danmakuArea") private var area = 0.5
  func makeCoordinator() -> Coordinator { Coordinator(store: store) }
  func makeUIViewController(context: Context) -> UIViewController {
    let controller = UIViewController()
    let surface = VideoLayerView()
    controller.view = surface
    surface.backgroundColor = .black
    surface.videoLayer.player = store.playback.player
    surface.videoLayer.videoGravity = .resizeAspect
    let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.holdSpeed(_:)))
    hold.minimumPressDuration = 0.35
    hold.allowableMovement = 20
    hold.delegate = context.coordinator
    surface.addGestureRecognizer(hold)
    let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.panVideo(_:)))
    pan.maximumNumberOfTouches = 1
    pan.delegate = context.coordinator
    surface.addGestureRecognizer(pan)
    context.coordinator.onSwipeDown = onSwipeDown
    surface.accessibilityHint = "横向拖动调整进度，向下滑动返回，长按临时加速"
    surface.accessibilityIdentifier = "video-player"
    context.coordinator.ready = surface.videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak store] _, change in
      let rendered = change.newValue ?? false
      Task { @MainActor in store?.playback.renderedFrame = rendered }
    }
    if let picture = AVPictureInPictureController(playerLayer: surface.videoLayer) {
      picture.canStartPictureInPictureAutomaticallyFromInline = true
      picture.delegate = context.coordinator
      context.coordinator.picture = picture
      context.coordinator.session = pip
      context.coordinator.host = controller
      Task { @MainActor in pip?.bind(picture) }
    }
    let canvas = context.coordinator.canvas
    canvas.onSpecialStatus = { [weak store] scripts, layers, unsupported in
      // Avoid invalidating SwiftUI every display refresh when the counts are unchanged.
      Task { @MainActor in
        if store?.specialScripts != scripts { store?.specialScripts = scripts }
        if store?.specialLayers != layers { store?.specialLayers = layers }
        if store?.unsupportedScripts != unsupported { store?.unsupportedScripts = unsupported }
      }
    }
    do {
      let overlay = controller.view!
      canvas.frame = overlay.bounds
      canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      overlay.addSubview(canvas)
      let caption = context.coordinator.caption
      caption.translatesAutoresizingMaskIntoConstraints = false
      overlay.addSubview(caption)
      let boost = context.coordinator.boost
      boost.translatesAutoresizingMaskIntoConstraints = false
      overlay.addSubview(boost)
      let preview = context.coordinator.seekPreview
      preview.translatesAutoresizingMaskIntoConstraints = false
      overlay.addSubview(preview)
      NSLayoutConstraint.activate([
        preview.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
        preview.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        preview.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 12),
        preview.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -12),
        caption.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
        caption.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 16),
        caption.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -16),
        caption.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -54),
        boost.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
        boost.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 54),
      ])
    }
    canvas.onPerformance = { [weak store] fps, cost in store?.danmakuPerformance = ["fps": fps, "meanRenderMS": cost] }
    canvas.player = store.playback.player
    return controller
  }
  func updateUIViewController(_ controller: UIViewController, context: Context) {
    context.coordinator.onSwipeDown = onSwipeDown
    if UIApplication.shared.applicationState != .active { context.coordinator.cancelPan() }
    context.coordinator.canvas.configure(items: store.danmaku.items, enabled: enabled, opacity: opacity, scale: scale, area: area, playing: store.playback.isPlaying, fullscreen: fullscreen)
    context.coordinator.caption.text = store.extras.text(at: store.playback.positionSeconds)
    context.coordinator.caption.isHidden = context.coordinator.caption.text?.isEmpty != false
    context.coordinator.boost.text = "  \(store.playback.boostLabel)  "
    context.coordinator.boost.isHidden = !store.playback.isBoosting
  }
  static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
    coordinator.ready = nil
    coordinator.canvas.stop()
    coordinator.cancelPan()
    coordinator.onSwipeDown = nil
    coordinator.store.playback.endTemporarySpeed()
    if coordinator.picture?.isPictureInPictureActive != true {
      (controller.view as? VideoLayerView)?.videoLayer.player = nil
    }
  }
  @MainActor final class Coordinator: NSObject, @preconcurrency AVPictureInPictureControllerDelegate, UIGestureRecognizerDelegate {
    var picture: AVPictureInPictureController?
    weak var session: MobilePiPSession?
    weak var host: UIViewController?
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
      session?.retainedHost = host
      session?.retainedDelegate = self
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
      session?.stopped()
    }
    let store: Store
    let canvas = MobileDanmakuCanvas()
    let caption: UILabel = {
      let label = UILabel()
      label.numberOfLines = 0
      label.font = .preferredFont(forTextStyle: .subheadline)
      label.textColor = .white
      label.backgroundColor = UIColor.black.withAlphaComponent(0.65)
      label.textAlignment = .center
      label.layer.cornerRadius = 6
      label.clipsToBounds = true
      label.isHidden = true
      return label
    }()
    var ready: NSKeyValueObservation?
    let boost: UILabel = {
      let label = UILabel()
      label.font = .preferredFont(forTextStyle: .caption1)
      label.textColor = .white
      label.backgroundColor = UIColor.black.withAlphaComponent(0.7)
      label.layer.cornerRadius = 10
      label.clipsToBounds = true
      label.isHidden = true
      label.accessibilityIdentifier = "temporary-speed-indicator"
      return label
    }()
    var onSwipeDown: (() -> Void)?
    private var panAxis: NSLayoutConstraint.Axis?
    private var seekStart = 0.0
    private var seekDuration = 0.0
    private var seekTarget = 0.0
    private var seekItem: AVPlayerItem?
    let seekPreview: UILabel = {
      let label = UILabel()
      label.font = .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
      label.textColor = .white
      label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
      label.textAlignment = .center
      label.layer.cornerRadius = 10
      label.clipsToBounds = true
      label.isHidden = true
      label.accessibilityIdentifier = "gesture-seek-preview"
      return label
    }()
    private var canSeek: Bool {
      store.playback.durationSeconds.isFinite && store.playback.durationSeconds > 0
        && store.playback.positionSeconds.isFinite && !store.playback.loading
        && store.playback.player.currentItem?.status == .readyToPlay
    }
    func cancelPan() {
      panAxis = nil
      seekItem = nil
      seekPreview.isHidden = true
    }
    @objc func panVideo(_ gesture: UIPanGestureRecognizer) {
      guard let view = gesture.view else { cancelPan(); return }
      switch gesture.state {
      case .began:
        store.playback.endTemporarySpeed()
        let velocity = gesture.velocity(in: view)
        panAxis = abs(velocity.x) > abs(velocity.y) ? .horizontal : .vertical
        if panAxis == .horizontal {
          guard canSeek else { cancelPan(); return }
          seekStart = max(0, min(store.playback.positionSeconds, store.playback.durationSeconds))
          seekDuration = store.playback.durationSeconds
          seekTarget = seekStart
          seekItem = store.playback.player.currentItem
          seekPreview.isHidden = false
        }
      case .changed:
        guard panAxis == .horizontal else { return }
        guard canSeek, seekItem === store.playback.player.currentItem else { cancelPan(); return }
        let delta = Double(gesture.translation(in: view).x / max(1, view.bounds.width)) * min(120, seekDuration)
        seekTarget = max(0, min(seekDuration, seekStart + delta))
        let seconds = Int((seekTarget - seekStart).rounded())
        seekPreview.text = "  \(clock(seekTarget)) / \(clock(seekDuration))  \(seconds >= 0 ? "+" : "")\(seconds) 秒  "
      case .ended:
        defer { cancelPan() }
        guard UIApplication.shared.applicationState == .active else { return }
        if panAxis == .horizontal {
          guard canSeek, seekItem === store.playback.player.currentItem,
            abs(gesture.translation(in: view).x) > 12 else { return }
          store.playback.seek(to: seekTarget)
        } else if panAxis == .vertical {
          let travel = gesture.translation(in: view)
          if travel.y > 72 && travel.y > abs(travel.x) * 1.3 { onSwipeDown?() }
        }
      case .cancelled, .failed: cancelPan()
      default: break
      }
    }
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
      guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view else { return true }
      guard UIApplication.shared.applicationState == .active, !store.playback.isBoosting else { return false }
      func editing(_ view: UIView) -> Bool {
        if view.isFirstResponder && (view is UITextField || view is UITextView) { return true }
        return view.subviews.contains(where: editing)
      }
      if let window = view.window, editing(window) { return false }
      let velocity = pan.velocity(in: view)
      if abs(velocity.x) > abs(velocity.y) * 1.3 { return canSeek }
      return velocity.y > abs(velocity.x) * 1.3 && onSwipeDown != nil
    }
    init(store: Store) { self.store = store }
    @objc func holdSpeed(_ gesture: UILongPressGestureRecognizer) {
      switch gesture.state {
      case .began:
        if store.playback.beginTemporarySpeed() {
          boost.text = "  \(store.playback.boostLabel)  "
          boost.isHidden = false
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          store.writeGestureQA("began")
        }
      case .ended, .cancelled, .failed:
        store.playback.endTemporarySpeed()
        boost.isHidden = true
        store.writeGestureQA("ended")
      default: break
      }
    }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      var view = touch.view
      while let current = view {
        if current is UIControl { return false }
        view = current.superview
      }
      return true
    }
    func gestureRecognizer(
      _ gesture: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { !(gesture is UIPanGestureRecognizer) && !(other is UIPanGestureRecognizer) }
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
      store.showPlayer = true
      completionHandler(true)
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
      session?.stopped()
      store.message = "画中画：" + error.localizedDescription
    }
  }
}
struct MiniVideo: UIViewRepresentable {
  let player: AVPlayer
  func makeUIView(context: Context) -> VideoLayerView {
    let view = VideoLayerView()
    view.videoLayer.player = player
    view.videoLayer.videoGravity = .resizeAspect
    return view
  }
  func updateUIView(_ view: VideoLayerView, context: Context) { view.videoLayer.player = player }
  static func dismantleUIView(_ view: VideoLayerView, coordinator: ()) {
    view.videoLayer.player = nil
  }
}
final class VideoLayerView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
struct MobileMiniPlayer: View {
  @Bindable var store: Store
  var body: some View {
    HStack(spacing: 10) {
      Button {
        store.showPlayer = true
      } label: {
        HStack {
          MiniVideo(player: store.playback.player).frame(width: 72, height: 42).background(.black)
            .clipShape(.rect(cornerRadius: 8))
          Text(store.playback.detail?.video.title ?? "准备播放").font(.caption.weight(.medium))
            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
      }.buttonStyle(.plain).accessibilityIdentifier("mini-player-open")
      Button {
        store.playback.togglePlayback()
      } label: {
        Image(systemName: store.playback.isPlaying ? "pause.fill" : "play.fill")
          .frame(width: 44, height: 44).contentShape(Rectangle())
      }.accessibilityLabel("播放或暂停")
      Button {
        store.closePlayback()
      } label: {
        Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
      }.accessibilityLabel("关闭播放器")
    }.padding(.horizontal, 16).padding(.vertical, 8)
  }
}
struct MobilePlayerContent: View {
  @Environment(\.columnNavigation) private var columns
  @Bindable var store: Store
  @Bindable var visit: MobileVideoVisit
  @State private var interaction: String?
  @State private var loginAfterInteraction = false
  @State private var details = false
  @State private var danmakuList = false
  @State private var danmakuSettings = false
  @State private var queueList: MobileQueueKind?
  @State private var dmText = ""
  @AppStorage("danmakuEnabled") private var dmEnabled = true
  @AppStorage("autoPlayNext") private var autoNext = false
  @AppStorage("autoPlayParts") private var autoParts = true
  @AppStorage("loopVideo") private var loop = false
  private var active: Bool {
    store.playerNavigation.active == visit.id || store.playerNavigation.root == nil
  }
  private var displayedDetail: Detail? { active ? store.playback.detail : visit.detail }
  var body: some View {
    Group {
      playerLayout
        .navigationTitle("正在播放").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          if store.playerNavigation.root?.id == visit.id || store.playerNavigation.root == nil {
            ToolbarItem(placement: .topBarLeading) {
              Button {
                store.returnFromPlayer()
              } label: {
                Image(systemName: "chevron.down")
              }.accessibilityLabel("收起播放器").accessibilityIdentifier("return-from-player")
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            if store.playerNavigation.root?.id != visit.id && store.playerNavigation.root != nil {
              Button {
                store.returnFromPlayer()
              } label: {
                Image(systemName: "chevron.down")
              }
              .accessibilityLabel("收起播放器").accessibilityIdentifier("return-from-player")
            }
            Button {
              details = true
            } label: {
              Image(systemName: "waveform.path.ecg")
            }.accessibilityLabel("播放详情")
          }
        }
        .task(id: store.playback.detail?.aid) {
          guard store.playerNavigation.active == visit.id || store.playerNavigation.root == nil,
            let detail = store.playback.detail, detail.aid > 0
          else { return }
          store.comments.loadIfNeeded(aid: detail.aid, api: store.api)
          #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--qa-favorites")
              || MobileFavoriteFixture.enabled
            {
              interaction = "favorite"
            }
          #endif
        }
        .task(id: store.playback.selectedCID) {
          let cid = store.playback.selectedCID
          guard cid > 0,
            store.playerNavigation.active == visit.id || store.playerNavigation.root == nil
          else { return }
          if store.playback.isOffline {
            store.danmaku.start(
              cid: cid, api: store.api, player: store.playback.player,
              localSidecar: store.playback.localDanmaku)
          } else if let detail = displayedDetail {
            store.danmaku.start(
              cid: cid, aid: detail.aid, api: store.api, player: store.playback.player)
            async let metadata: () = store.extras.load(detail: detail, cid: cid, api: store.api)
            async let actions: () = store.actions.load(
              detail: detail, accountID: store.account?.mid, api: store.api)
            _ = await (metadata, actions)
          }
        }
        .sheet(isPresented: $details) { MobilePlaybackDetails(store: store) }
        .sheet(isPresented: $danmakuSettings) { MobileDanmakuSettings() }
        .sheet(item: $queueList) { MobileQueueList(store: store, kind: $0) }
        .sheet(isPresented: $danmakuList) {
          NavigationStack {
            List {
              ForEach(store.danmaku.items) { item in
                Button {
                  store.playback.seek(to: item.time)
                  danmakuList = false
                } label: {
                  HStack(alignment: .top) {
                    Text(clock(item.time)).font(.caption.monospacedDigit())
                    Text(
                      item.mode == 8
                        ? "代码弹幕 · 与电脑版相同，暂不执行"
                        : item.mode == 9
                          ? "BAS 动画弹幕"
                          : item.mode == 7 ? AdvancedDanmaku(item.text)?.text ?? "定位弹幕" : item.text
                    )
                    .lineLimit(3)
                  }
                }.foregroundStyle(.primary)
              }
            }.navigationTitle("已加载弹幕").toolbar { Button("完成") { danmakuList = false } }
          }
        }
        .sheet(
          item: Binding(
            get: { interaction.map { ActionTarget(name: $0) } }, set: { interaction = $0?.name }),
          onDismiss: {
            if loginAfterInteraction { loginAfterInteraction = false; store.login() }
          }
        ) { target in
          if let detail = displayedDetail {
            MobileInteractionSheet(store: store, detail: detail, kind: target.name) {
              loginAfterInteraction = true
              interaction = nil
            }
          }
        }
    }
  }
  @ViewBuilder private var playerLayout: some View {
    if columns || UIDevice.current.userInterfaceIdiom == .pad {
      GeometryReader { geometry in
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            video.frame(height: min(min(1280, max(0, geometry.size.width - 40)) * 9 / 16,
              max(180, geometry.size.height - 170)))
            information
          }.frame(maxWidth: 1280).padding(20).frame(maxWidth: .infinity)
        }.scrollDismissesKeyboard(.interactively).scrollPosition($visit.scroll)
          .accessibilityIdentifier("player-information")
      }
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          video.aspectRatio(16 / 9, contentMode: .fit)
          information.padding(.horizontal, 16).padding(.bottom, 16)
        }
      }.scrollDismissesKeyboard(.interactively).scrollPosition($visit.scroll)
    }
  }
  private var video: some View {
    Group {
      if active { MobileVideoPlayer(store: store) } else { Color.black }
    }.background(.black).clipShape(.rect(cornerRadius: UIDevice.current.userInterfaceIdiom == .pad ? 16 : 0))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("player-viewport")
  }
  private var information: some View {
    VStack(alignment: .leading, spacing: 18) {
      if store.playback.buffering && !store.playback.loading {
        Label("正在缓冲…", systemImage: "arrow.trianglehead.2.clockwise")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = store.playback.error {
        MobileError(text: error) { store.playback.retry(api: store.api) }
      }
      if let detail = displayedDetail {
        Text(detail.video.title).font(.title3.bold()).textSelection(.enabled)
          .accessibilityIdentifier("player-title")
        ViewThatFits(in: .horizontal) {
          HStack {
            MobileProfileLink(store: store, mid: detail.ownerID) {
              Label(detail.video.author, systemImage: "person.crop.circle")
                .accessibilityIdentifier("player-author")
            }
            Spacer()
            Text(detail.video.bvid).font(.caption).foregroundStyle(.secondary)
          }
          VStack(alignment: .leading, spacing: 8) {
            MobileProfileLink(store: store, mid: detail.ownerID) {
              Label(detail.video.author, systemImage: "person.crop.circle")
                .accessibilityIdentifier("player-author")
            }
            Text(detail.video.bvid).font(.caption).foregroundStyle(.secondary)
          }
        }
        if let date = detail.video.publishedAt {
          Text(date.formatted(AppDateFormat.timestamp)).font(.caption).foregroundStyle(
            .secondary)
        }
        if detail.aid > 0 {
          actionBar(detail)
          danmakuInput(detail)
        }
        playbackOptions
        if let error = store.extras.subtitleError {
          Text("字幕：" + error).font(.caption).foregroundStyle(.secondary)
        }
        if let error = store.danmaku.error ?? store.danmaku.specialError {
          Text("弹幕：" + error).font(.caption).foregroundStyle(.secondary)
        }
        Picker("内容", selection: $visit.section) {
          Text("简介").tag(0)
          Text(commentTitle(detail)).tag(1)
        }.pickerStyle(.segmented)
        if visit.section == 1 && detail.aid > 0 {
          MobileComments(store: store, aid: detail.aid, model: visit.comments)
        } else {
          description(detail)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func commentTitle(_ detail: Detail) -> String {
    let count = visit.comments.hasLoadedCount ? visit.comments.count : detail.counts.replies
    return count.map { "评论 \($0)" } ?? "评论"
  }
  private struct ActionTarget: Identifiable {
    let name: String
    var id: String { name }
  }
  private var playbackOptions: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 12) {
          Menu {
            Toggle("分 P 自动连播", isOn: $autoParts)
            Toggle("合集与播放列表自动连播", isOn: $autoNext)
            Toggle("单集循环", isOn: $loop)
            if store.hasNext { Button("下一集") { store.next() } }
            Button("弹幕列表") { danmakuList = true }
            Button("弹幕设置") { danmakuSettings = true }
          } label: {
            Image(systemName: "list.bullet")
          }.accessibilityLabel("播放选项")
          if let detail = store.playback.detail, store.playback.streams != nil {
            Button {
              store.downloads.enqueue(
                video: detail.video, cid: store.playback.selectedCID,
                qn: store.playback.selectedQuality, api: store.api, cached: true)
              interaction = "download"
            } label: {
              Image(systemName: "arrow.down.circle")
            }.accessibilityLabel("下载当前视频")
          }
        }.buttonStyle(.plain).font(.subheadline.weight(.medium))
          .padding(.horizontal, 2).padding(.vertical, 6)
    }
  }
  private func actionBar(_ detail: Detail) -> some View {
    MobileActionBar(store: store, detail: detail) { authenticate($0) }
  }

  private func authenticate(_ name: String) {
    if store.account == nil { store.login() } else { interaction = name }
  }
  private func danmakuInput(_ detail: Detail) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField(
          "发一条弹幕",
          text: Binding(get: { store.danmaku.message }, set: { store.danmaku.message = $0 })
        ).textFieldStyle(.roundedBorder).accessibilityIdentifier("danmaku-input")
        Button("发送") {
          if store.account == nil {
            store.login()
          } else {
            Task {
              await store.danmaku.send(
                aid: detail.aid, api: store.api, player: store.playback.player)
            }
          }
        }.disabled(
          store.danmaku.sending
            || store.danmaku.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || store.danmaku.message.count > 100)
      }
      if let error = store.danmaku.sendError {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
  }
  private func sequenceButton(_ kind: MobileQueueKind, title: String, subtitle: String) -> some View {
    Button { queueList = kind } label: {
      HStack(spacing: 12) {
        Image(systemName: kind == .parts ? "rectangle.split.3x1" : "rectangle.stack").font(.title2)
        VStack(alignment: .leading, spacing: 6) {
          Text(title).font(.headline)
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        Image(systemName: "chevron.right")
      }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 14))
    }.buttonStyle(InterfacePressStyle()).accessibilityIdentifier("sequence-" + kind.rawValue)
  }
  @ViewBuilder private func description(_ detail: Detail) -> some View {
    let subtitle = store.extras.text(at: store.playback.positionSeconds)
    if !subtitle.isEmpty {
      Text(subtitle).font(.headline).padding().frame(maxWidth: .infinity).background(
        .regularMaterial, in: .rect(cornerRadius: 12)
      ).accessibilityLabel("当前字幕：" + subtitle)
    }
    if detail.pages.count > 1 {
      sequenceButton(.parts, title: "分 P · \(detail.pages.count) P", subtitle: "当前视频的不同分段")
    }
    if let collection = detail.collection, !collection.items.isEmpty {
      sequenceButton(.collection, title: "合集 · " + collection.title, subtitle: "\(collection.items.count) 个视频")
    }
    if !store.queue.isEmpty && detail.collection == nil {
      sequenceButton(.playlist, title: "播放列表", subtitle: "\(store.queue.count) 个视频")
    }
    Text(detail.description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
    if !store.extras.tags.isEmpty {
      ScrollView(.horizontal) {
        HStack {
          ForEach(store.extras.tags) { tag in
            Text(tag.title).font(.caption).padding(8).background(.quaternary, in: .capsule)
          }
        }
      }
    }
    if let error = store.extras.error {
      MobileError(text: error) {
        Task {
          await store.extras.load(
            detail: detail, cid: store.playback.selectedCID, api: store.api, refresh: true)
        }
      }
    }
    if !store.extras.related.isEmpty {
      Text("相关推荐").font(.headline)
      MobileVideoGrid(videos: store.extras.related, store: store)
    }
  }
}
enum MobileQueueKind: String, Identifiable {
  case parts, collection, playlist
  var id: String { rawValue }
}
struct MobileQueueList: View {
  @Bindable var store: Store
  let kind: MobileQueueKind
  @AppStorage("autoPlayParts") private var autoParts = true
  @AppStorage("autoPlayNext") private var autoNext = false
  private var items: [PlaybackQueueItem] {
    switch kind {
    case .parts: PlaybackSequence.parts(store.playback.detail)
    case .collection: store.playback.detail?.collection?.items ?? []
    case .playlist: store.queue
    }
  }
  private var title: String {
    switch kind {
    case .parts: "分 P"
    case .collection: "合集 · " + (store.playback.detail?.collection?.title ?? "")
    case .playlist: "播放列表"
    }
  }
  @Environment(\.dismiss) private var dismiss
  private func isCurrent(_ item: PlaybackQueueItem) -> Bool {
    item.bvid == store.playback.detail?.video.bvid
      && (kind != .parts || item.cid == store.playback.selectedCID)
  }
  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        List {
          Section {
            if kind == .parts { Toggle("分 P 自动连播", isOn: $autoParts) }
            else { Toggle("合集与播放列表自动连播", isOn: $autoNext) }
          }
          Section {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
              Button {
                if !isCurrent(item) {
                  if kind != .parts { store.queue = items }
                  store.advance(to: item)
                }
                dismiss()
              } label: {
                HStack(spacing: 12) {
                  Text(String(index + 1)).monospacedDigit().frame(minWidth: 28)
                    .foregroundStyle(.secondary)
                  VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.subheadline).lineLimit(3)
                    if isCurrent(item) {
                      Label("正在播放", systemImage: "waveform").font(.caption).foregroundStyle(
                        biliPink)
                    }
                  }
                  Spacer(minLength: 4)
                  if isCurrent(item) { Image(systemName: "play.fill").foregroundStyle(biliPink) }
                }.frame(minHeight: 48).contentShape(Rectangle())
              }.buttonStyle(.plain).id(item.id)
            }
          } header: {
            Text(kind == .parts ? "共 \(items.count) P" : "共 \(items.count) 个视频")
          }
        }.onAppear {
          if let current = items.first(where: isCurrent) {
            proxy.scrollTo(current.id, anchor: .center)
          }
        }
      }.navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline).toolbar { Button("完成") { dismiss() } }
    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
  }
}
struct MobilePlaybackDetails: View {
  @Bindable var store: Store
  @State private var stats: [String: Int] = [:]
  @State private var network: [String: Int] = [:]
  @State private var attempts: [[String: String]] = []
  @State private var copied = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        LabeledContent("实际分辨率", value: store.playback.actualSize)
        LabeledContent("格式", value: store.playback.sourceFormat)
        LabeledContent("实际出画", value: store.playback.renderedFrame ? "是" : "尚未确认")
          .accessibilityElement(children: .ignore).accessibilityLabel("实际出画")
          .accessibilityValue(store.playback.renderedFrame ? "是" : "尚未确认")
          .accessibilityIdentifier("rendered-frame-status")
        LabeledContent("播放位置", value: clock(store.playback.positionSeconds))
        LabeledContent("当前倍速", value: "\(Double(store.playback.player.rate).formatted())×")
        LabeledContent("长按加速", value: store.playback.isBoosting ? "进行中" : "未启用")
          .accessibilityElement(children: .ignore).accessibilityLabel("长按加速")
          .accessibilityValue(store.playback.isBoosting ? "进行中" : "未启用")
          .accessibilityIdentifier("temporary-speed-status")
        LabeledContent("高级弹幕脚本", value: String(store.specialScripts))
        LabeledContent("高级弹幕图层", value: String(store.specialLayers))
          .accessibilityElement(children: .ignore).accessibilityLabel("高级弹幕图层")
          .accessibilityValue(String(store.specialLayers)).accessibilityIdentifier(
            "special-layer-count")
        if store.unsupportedScripts > 0 {
          LabeledContent("暂不支持的脚本", value: String(store.unsupportedScripts))
        }
        ForEach(store.playback.routeDiagnostics.keys.filter { !$0.hasPrefix("manifest.") }.sorted(), id: \.self) { key in
          LabeledContent(key, value: store.playback.routeDiagnostics[key] ?? "")
        }
        Section("播放诊断") {
          if !store.playback.failureCode.isEmpty { LabeledContent("错误代码", value: store.playback.failureCode) }
          if let available = store.playback.routeDiagnostics["manifest.video.available"] {
            LabeledContent("可用视频流", value: available)
            LabeledContent("可用音频流", value: store.playback.routeDiagnostics["manifest.audio.available"] ?? "—")
          }
          Button(copied ? "已复制诊断信息" : "复制播放诊断") {
            Task { UIPasteboard.general.string = await store.playback.diagnosticReport(); copied = true }
          }
          Text("包含版本、播放阶段和线路错误；不包含登录凭据或完整媒体地址。")
            .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(stats.keys.sorted(), id: \.self) { key in
          LabeledContent(key, value: String(stats[key] ?? 0))
        }
        Section("网络传输") {
          ForEach(network.keys.sorted(), id: \.self) { key in
            LabeledContent(key, value: String(network[key] ?? 0))
          }
        }
        Section("起播耗时（毫秒）") {
          ForEach(store.playback.startupMilliseconds.keys.sorted(), id: \.self) { key in
            LabeledContent(key, value: String(store.playback.startupMilliseconds[key] ?? 0))
          }
        }
        Section("CDN 试读记录") {
          ForEach(Array(attempts.enumerated()), id: \.offset) { _, attempt in
            VStack(alignment: .leading) {
              ForEach(attempt.keys.sorted(), id: \.self) { key in
                LabeledContent(key, value: attempt[key] ?? "")
              }
            }.font(.caption)
          }
        }
      }.navigationTitle("播放详情").toolbar { Button("完成") { dismiss() } }.task {
        while !Task.isCancelled {
          stats = await store.playback.transferStats()
          network = await store.playback.networkStats()
          attempts = await store.playback.cdnAttempts()
          do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
      }
    }
  }
}
