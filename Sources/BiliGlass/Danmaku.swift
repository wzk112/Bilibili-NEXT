import AVFoundation
import AppKit
import SwiftUI

@MainActor final class SpecialDanmakuCache {
  var source: [Danmaku] = []
  var compilation = SpecialCompilation()
}
@MainActor final class DanmakuView: NSView {
  var player: AVPlayer? { didSet { if player !== oldValue { observePlayer(oldValue) } } }
  private var controlObservation: NSKeyValueObservation?
  private var rateObservation: NSKeyValueObservation?
  private var playerTimeObserver: Any?
  private var visibilityObservers: [NSObjectProtocol] = []
  private var defaultsObserver: NSObjectProtocol?
  private var wakeTask: Task<Void, Never>?
  private var clockTicks = 0
  var compilationCache: SpecialDanmakuCache?
  var items: [Danmaku] = [] {
    didSet { invalidatePlan(preservingRunning: true); compileSpecial(); refreshClock() }
  }
  let specialRenderer = SpecialDanmakuRenderer()
  var onSpecialStatus: ((Int, Int) -> Void)?
  private var specialTask: Task<Void, Never>?
  private var specialSource: [Danmaku] = []
  private var plannedSize = CGSize.zero
  var enabled = true { didSet { if enabled != oldValue { refreshClock() } } }
  var bottomInset: CGFloat = 12 { didSet { if bottomInset != oldValue { invalidatePlan(); lastTime = -1 } } }
  var topInset: CGFloat = 12 { didSet { if topInset != oldValue { invalidatePlan(); lastTime = -1 } } }
  private var frameLink: CADisplayLink?
  @MainActor private final class FrameTarget: NSObject {
    weak var view: DanmakuView?
    @objc func frame(_ link: CADisplayLink) { view?.clockTicks += 1; view?.tick() }
  }
  private let frameTarget = FrameTarget()
  private var task: Task<Void, Never>?
  private var revision = UUID()
  private var plannedWidth: CGFloat = -1
  private var windowStart = -1.0
  private var windowEnd = -1.0
  private var plan: [DanmakuPlacement] = []
  private var textLayers: [String: CALayer] = [:]
  private var lastTime = -1.0
  private var lastPlaybackTime: Double?
  private var planning = false
  private var invalidated = true
  private var preserveRunning = false
  private var style = ""
  private var sampleStart = CACurrentMediaTime()
  private var sampleFrames = 0
  private var sampleRenderTime = 0.0
  private var measuredFPS = 0.0
  private var meanRenderMilliseconds = 0.0
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.masksToBounds = true
    layer?.isGeometryFlipped = true
    layer?.addSublayer(specialRenderer.root)
    specialRenderer.didPrepare = { [weak self] in self?.lastTime = -1; self?.tick() }
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.style != self.currentStyle else { return }
        self.refreshClock()
      }
    }
    frameTarget.view = self
    let link = displayLink(target: frameTarget, selector: #selector(FrameTarget.frame(_:)))
    link.isPaused = true
    link.add(to: .main, forMode: .common)
    frameLink = link
  }
  required init?(coder: NSCoder) { fatalError() }
  isolated deinit {
    frameLink?.invalidate()
    wakeTask?.cancel()
    visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
    if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    if let playerTimeObserver { player?.removeTimeObserver(playerTimeObserver) }
    task?.cancel()
    specialTask?.cancel()
  }
  func statistics() -> [String: Any] {
    [
      "displayLinkPaused": frameLink?.isPaused ?? true, "clockTicks": clockTicks,
      "items": items.count, "planned": plan.count, "layers": textLayers.count,
      "specialLayers": specialRenderer.count, "specialScripts": specialRenderer.compilation.scripts.count, "unsupportedScripts": specialRenderer.compilation.unsupported,
      "width": bounds.width, "height": bounds.height, "visible": !visibleRect.isEmpty,
      "attached": superview != nil, "window": window != nil,
      "measuredFPS": measuredFPS, "meanRenderMilliseconds": meanRenderMilliseconds,
      "displayMaximumFPS": window?.screen?.maximumFramesPerSecond ?? 0,
      "parentWidth": superview?.bounds.width ?? 0, "parentHeight": superview?.bounds.height ?? 0,
    ]
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    let rate = Float(window?.screen?.maximumFramesPerSecond ?? 60)
    frameLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60,rate), maximum: rate, preferred: rate)
    visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
    visibilityObservers = []
    if let window {
      visibilityObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.refreshClock() }
      })
    }
    if let clip = enclosingScrollView?.contentView {
      clip.postsBoundsChangedNotifications = true
      visibilityObservers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.refreshClock() }
      })
    }
    lastTime = -1
    refreshClock()
  }
  private func observePlayer(_ old: AVPlayer?) {
    if let playerTimeObserver { old?.removeTimeObserver(playerTimeObserver) }
    playerTimeObserver = nil; controlObservation = nil; rateObservation = nil
    if let player {
      controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.refreshClock() }
      }
      rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
        Task { @MainActor in self?.refreshClock() }
      }
      playerTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { if self?.frameLink?.isPaused == true { self?.refreshClock() } }
      }
    }
    lastPlaybackTime = nil
    invalidatePlan()
    lastTime = -1
    refreshClock()
  }
  private func refreshClock() { wakeTask?.cancel(); wakeTask = nil; lastTime = -1; tick() }
  override func layout() { super.layout(); refreshClock() }
  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() {}
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard enabled, !isHidden else { return nil }
    return specialRenderer.hit(convert(point, from: superview)) == nil ? nil : self
  }
  override func mouseDown(with event: NSEvent) {
    if let target = specialRenderer.hit(convert(event.locationInWindow, from: nil)) {
      if case .object("seek", let values) = target, let raw = values["time"]?.scalar,
        let duration = player?.currentItem?.duration.seconds, duration.isFinite {
        player?.seek(to: CMTime(seconds: min(duration,max(0,raw)), preferredTimescale: 600))
      } else { specialRenderer.activate?(target) }
    }
  }
  private func compileSpecial() {
    let source = items.filter { [7,8,9].contains($0.mode) }
    guard source != specialSource else { return }
    specialSource = source
    if source.isEmpty {
      specialTask?.cancel(); specialTask = nil
      specialRenderer.replace(SpecialCompilation())
      return
    }
    if let cache = compilationCache, cache.source == source {
      specialTask?.cancel(); specialTask = nil
      specialRenderer.replace(cache.compilation)
      lastTime = -1; tick()
      return
    }
    guard specialTask == nil else { return }
    specialTask = Task { [weak self] in
      while let self, !Task.isCancelled {
        let pending = specialSource
        let previous = specialRenderer.compilation
        let worker = Task.detached(priority: .utility) { SpecialCompilation.compile(pending, reusing: previous) }
        let compilation = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        compilationCache?.source = pending
        compilationCache?.compilation = compilation
        specialRenderer.replace(compilation)
        onSpecialStatus?(compilation.scripts.count, compilation.unsupported)
        lastTime = -1; tick()
        if pending == specialSource { specialTask = nil; return }
      }
    }
  }
  private var textScale: CGFloat {
    max(0.5, min(2, UserDefaults.standard.object(forKey: "danmakuScale") as? Double ?? 1))
  }
  private func invalidatePlan(preservingRunning: Bool = false) {
    // Keep a reset sticky until a compatible plan finishes, even if another
    // segment arrives while the replacement is being computed.
    if !preservingRunning { preserveRunning = false }
    invalidated = true
    revision = UUID()
    task?.cancel()
    planning = false
    plannedWidth = -1
  }
  private var currentStyle: String {
    ["danmakuScale", "danmakuArea", "danmakuDuration", "danmakuOpacity", "danmakuScrolling",
      "danmakuTop", "danmakuBottom", "danmakuColored", "danmakuAvoidSubtitles",
      "danmakuDeduplicate", "danmakuBlockedWords"].map {
        String(describing: UserDefaults.standard.object(forKey: $0))
      }.joined(separator: ":") + ":" + String(UserDefaults.standard.data(forKey: "danmakuCloudRules")?.hashValue ?? 0)
  }
  private func requestPlan(time: Double) {
    guard !planning, bounds.width > 0, bounds.height > 0 else { return }
    planning = true
    let token = revision
    let source = items
    let size = bounds.size
    let inset = topInset, bottom = bottomInset
    let options = DanmakuDisplayOptions.read()
    let scale = textScale
    let area = max(
      0.2, min(1, UserDefaults.standard.object(forKey: "danmakuArea") as? Double ?? 0.5))
    let duration = max(
      3, min(15, UserDefaults.standard.object(forKey: "danmakuDuration") as? Double ?? 8))
    let continuous = size == plannedSize && preserveRunning
      && lastPlaybackTime.map { time >= $0 && time - $0 < 1 } == true
    let previous: [DanmakuPlacement]? = continuous ? plan : nil
    invalidated = false
    task = Task { [weak self] in
      let worker = Task.detached(priority: .userInitiated) {
        DanmakuLayout.prepare(
          items: source, size: size, scale: scale, area: area, duration: duration, time: time,
          topInset: inset, bottomInset: bottom, options: options, retaining: previous)
      }
      let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
      guard let self, !Task.isCancelled, token == revision else { return }
      guard size == bounds.size else {
        planning = false
        return
      }
      plan = result
      preserveRunning = true
      if !continuous {
        textLayers.values.forEach { $0.removeFromSuperlayer() }
        textLayers = [:]
      }
      plannedWidth = size.width
      plannedSize = size
      windowStart = max(0, time - 20)
      windowEnd = time + 60
      planning = false
      lastTime = -1
      tick()
    }
  }
  private func tick() {
    guard enabled, !isHiddenOrHasHiddenAncestor, window?.isVisible == true, window?.occlusionState.contains(.visible) == true, !visibleRect.isEmpty, let player else {
      if !textLayers.isEmpty {
        textLayers.values.forEach { $0.removeFromSuperlayer() }
        textLayers = [:]
      }
      if specialRenderer.count > 0 { specialRenderer.clear() }
      frameLink?.isPaused = true
      wakeTask?.cancel(); wakeTask = nil
      lastTime = -1
      return
    }
    let defaults = UserDefaults.standard
    let currentStyle = self.currentStyle
    if currentStyle != style {
      style = currentStyle
      invalidatePlan()
      textLayers.values.forEach { $0.removeFromSuperlayer() }
      textLayers = [:]
      lastTime = -1
    }
    guard player.timeControlStatus != .waitingToPlayAtSpecifiedRate else { frameLink?.isPaused = true; return }
    let time = player.currentTime().seconds
    guard time.isFinite else { return }
    if let previousTime = lastPlaybackTime, time < previousTime - 0.1 || time - previousTime > 1 {
      invalidatePlan()
    }
    if invalidated || plannedWidth != bounds.width || plannedSize != bounds.size || time < windowStart || time > windowEnd - 10 {
      requestPlan(time: time)
    }
    lastPlaybackTime = time
    let hasVisible = plan.contains { $0.item.time <= time && time < $0.item.time + $0.duration }
      || specialRenderer.compilation.scripts.contains { $0.item.time <= time && time < $0.item.time + $0.duration }
    frameLink?.isPaused = player.timeControlStatus != .playing || !hasVisible
    if !hasVisible, player.timeControlStatus == .playing, wakeTask == nil,
       let next = items.lazy.filter({ $0.time > time }).map(\.time).min() {
      let delay = min(60, max(0.001, (next - time) / Double(max(0.1, player.rate))))
      wakeTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        self?.wakeTask = nil; self?.tick()
      }
    }
    if !hasVisible && textLayers.isEmpty && specialRenderer.count == 0 { lastTime = time; return }
    guard time != lastTime || plannedSize != bounds.size else { return }
    lastTime = time
    let renderStart = CACurrentMediaTime()
    defer {
      let now = CACurrentMediaTime()
      if player.rate == 0 { sampleStart = now; sampleFrames = 0; sampleRenderTime = 0 }
      else {
        sampleFrames += 1; sampleRenderTime += now-renderStart
        if now-sampleStart >= 2 {
          measuredFPS = Double(sampleFrames)/(now-sampleStart)
          meanRenderMilliseconds = sampleRenderTime*1000/Double(sampleFrames)
          sampleStart = now; sampleFrames = 0; sampleRenderTime = 0
        }
      }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    specialRenderer.render(time: time, size: bounds.size, backingScale: window?.backingScaleFactor ?? 2,
      opacity: Float(max(0.1,min(1,defaults.object(forKey:"danmakuOpacity") as? Double ?? 0.85))))
    var visible = Set<String>()
    for placement in plan
    where placement.item.time <= time && time - placement.item.time < placement.duration {
      guard visible.count < 150 else { break }
      let item = placement.item
      let text = DanmakuLayout.displayText(item.text)
      visible.insert(item.id)
      let textLayer: CALayer
      if let existing = textLayers[item.id] {
        textLayer = existing
      } else {
        textLayer = CALayer()
        textLayer.anchorPoint = .zero
        textLayer.contentsScale = window?.backingScaleFactor ?? 2
        textLayer.bounds = CGRect(x: 0, y: 0, width: placement.width, height: placement.height)
        textLayer.contents = DanmakuTextBitmap.make(text: text, fontSize: placement.fontSize, color: item.color,
          size: textLayer.bounds.size, scale: textLayer.contentsScale)
        // The outline and solid fill share one cached bitmap, including on a flipped layer.
        layer?.addSublayer(textLayer)
        textLayers[item.id] = textLayer
      }
      textLayer.opacity =
        Float(
          max(
            0.1, min(1, UserDefaults.standard.object(forKey: "danmakuOpacity") as? Double ?? 0.85)))
      textLayer.position = CGPoint(x: placement.x(at: time, viewportWidth: bounds.width), y: placement.y)
    }
    for id in Array(textLayers.keys) where !visible.contains(id) {
      textLayers.removeValue(forKey: id)?.removeFromSuperlayer()
    }
  }
}

struct DanmakuOverlay: NSViewRepresentable {
  let player: AVPlayer
  let items: [Danmaku]
  let enabled: Bool
  func makeNSView(context: Context) -> DanmakuView {
    let v = DanmakuView()
    v.player = player
    return v
  }
  func updateNSView(_ view: DanmakuView, context: Context) {
    view.player = player
    if view.items != items {
      view.items = items
    }
    view.enabled = enabled
    view.isHidden = !enabled
    view.needsDisplay = true
  }
}
