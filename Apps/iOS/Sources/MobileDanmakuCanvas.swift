import AVFoundation
import UIKit

/// Shares the desktop client's layout and CoreText outline/fill bitmap path.
/// Display refreshes move cached glyph layers; text is never re-rasterized per frame.
@MainActor final class MobileDanmakuCanvas: UIView {
  weak var player: AVPlayer?
  private var link: CADisplayLink?
  private var items: [Danmaku] = []
  private var plan: [DanmakuPlacement] = []
  private var textLayers: [String: CALayer] = [:]
  private var enabled = true
  private var playing = false
  private var opacity = 0.85
  private var scale = 1.0
  private var area = 0.5
  private var duration = 8.0
  private var options = DanmakuDisplayOptions()
  private var invalidated = true
  private var preserveRunning = false
  private var plannedAt = -Double.infinity
  private var planTask: Task<Void, Never>?
  private var revision = UUID()
  private var fullscreen = false
  var onPerformance: ((Double, Double) -> Void)?
  private var sampleStart = CACurrentMediaTime()
  private var sampleFrames = 0
  private var sampleCost = 0.0
  private var plannedRect = CGRect.zero
  private var lastTime = -Double.infinity
  private var wakeTask: Task<Void, Never>?
  private var defaultsObserver: NSObjectProtocol?
  private let special = SpecialDanmakuRenderer()
  private var specialSource: [Danmaku] = []
  private var specialTask: Task<Void, Never>?
  var onSpecialStatus: ((Int, Int, Int) -> Void)?
  private var reportedSpecial = [-1, -1, -1]
  private func reportSpecial() {
    let counts = [
      special.compilation.scripts.count, special.count, special.compilation.unsupported,
    ]
    guard counts != reportedSpecial else { return }
    reportedSpecial = counts
    onSpecialStatus?(counts[0], counts[1], counts[2])
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = true
    backgroundColor = .clear
    clipsToBounds = true
    layer.backgroundColor = UIColor.clear.cgColor
    layer.addSublayer(special.root)
    special.didPrepare = { [weak self] in self?.tick() }
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        if let self, self.readOptions() {
          self.invalidatePlan()
          self.tick()
        }
      }
    }
    readOptions()
  }
  convenience init() { self.init(frame: .zero) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(
    items: [Danmaku], enabled: Bool, opacity: Double, scale: Double, area: Double, playing: Bool, fullscreen: Bool = false
  ) {
    if self.items != items {
      invalidatePlan(preservingRunning: true)
      compileSpecial(items)
    }
    if self.scale != scale || self.area != area || self.fullscreen != fullscreen { invalidatePlan() }
    self.fullscreen = fullscreen
    self.items = items
    self.enabled = enabled
    self.opacity = opacity
    self.scale = scale
    self.area = area
    self.playing = playing
    isHidden = !enabled
    ensureLink()
    tick()
  }
  @discardableResult private func readOptions() -> Bool {
    let nextDuration = UserDefaults.standard.object(forKey: "danmakuDuration") as? Double ?? 8
    let next = DanmakuDisplayOptions.read()
    let changed = duration != nextDuration || options != next
    duration = nextDuration
    options = next
    return changed
  }
  private func invalidatePlan(preservingRunning: Bool = false) {
    preserveRunning = preservingRunning
    invalidated = true
    revision = UUID()
    planTask?.cancel()
    planTask = nil
  }
  private func requestPlan(time: Double, rect: CGRect) {
    guard planTask == nil else { return }
    let source = items, token = revision, options = options
    let textScale = scale * max(0.5, min(1, rect.height / 360))
    let area = area, duration = duration
    let insets = DanmakuLayout.mobileInsets(height: rect.height, fullscreen: fullscreen)
    let continuous = rect == plannedRect && (!invalidated || preserveRunning)
      && time >= lastTime && time - lastTime < 1
    let previous = continuous ? plan : []
    let clear = !continuous
    invalidated = false
    planTask = Task { [weak self] in
      let worker = Task.detached(priority: .userInitiated) {
        DanmakuLayout.prepare(items: source, size: rect.size, scale: textScale, area: area,
          duration: duration, time: time, topInset: insets.top, bottomInset: insets.bottom,
          options: options, retaining: previous)
      }
      let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
      guard let self, !Task.isCancelled, token == self.revision else { return }
      self.planTask = nil
      guard rect == self.videoRect else { self.invalidated = true; return }
      self.plan = result
      if clear { self.clearLayers() }
      self.plannedAt = time
      self.plannedRect = rect
      self.tick()
    }
  }
  private func compileSpecial(_ items: [Danmaku]) {
    let source = items.filter { [7, 8, 9].contains($0.mode) }
    guard source != specialSource else { return }
    specialSource = source
    if source.isEmpty {
      specialTask?.cancel()
      specialTask = nil
      special.replace(.init())
      reportSpecial()
      return
    }
    guard specialTask == nil else { return }
    specialTask = Task { [weak self] in
      while let self, !Task.isCancelled {
        let pending = specialSource
        let previous = special.compilation
        let worker = Task.detached(priority: .utility) {
          SpecialCompilation.compile(pending, reusing: previous)
        }
        let result = await withTaskCancellationHandler {
          await worker.value
        } onCancel: {
          worker.cancel()
        }
        guard !Task.isCancelled else { return }
        special.replace(result)
        tick()
        if pending == specialSource {
          specialTask = nil
          return
        }
      }
    }
  }
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    enabled && !isHidden && special.hit(special.root.convert(point, from: layer)) != nil
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let point = touches.first?.location(in: self),
      let target = special.hit(special.root.convert(point, from: layer))
    else { return }
    if case .object("seek", let values) = target, let time = values["time"]?.scalar,
      let duration = player?.currentItem?.duration.seconds, duration.isFinite
    {
      player?.seek(to: CMTime(seconds: min(duration, max(0, time)), preferredTimescale: 600))
    } else {
      special.activate?(target)
    }
  }
  private var videoRect: CGRect {
    guard let size = player?.currentItem?.presentationSize, size.width > 0, size.height > 0 else {
      return bounds
    }
    return AVMakeRect(aspectRatio: size, insideRect: bounds)
  }
  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      stop()
    } else {
      ensureLink()
      invalidatePlan()
      tick()
    }
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    if videoRect != plannedRect {
      invalidatePlan()
      tick()
    }
  }
  private func ensureLink() {
    guard window != nil, link == nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(frameTick))
    let maximum = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: 30, maximum: maximum, preferred: maximum)
    link.add(to: .main, forMode: .common)
    self.link = link
  }
  @objc private func frameTick() {
    let began = CACurrentMediaTime()
    tick()
    let now = CACurrentMediaTime()
    sampleFrames += 1
    sampleCost += now - began
    if now - sampleStart >= 2 {
      onPerformance?(Double(sampleFrames) / (now - sampleStart), sampleCost * 1000 / Double(sampleFrames))
      sampleStart = now; sampleFrames = 0; sampleCost = 0
    }
  }
  private func clearLayers() {
    for layer in textLayers.values { layer.removeFromSuperlayer() }
    textLayers.removeAll(keepingCapacity: true)
  }
  private func tick() {
    guard window != nil, enabled, let time = player?.currentTime().seconds, time.isFinite,
      bounds.width > 0
    else {
      link?.isPaused = true
      clearLayers()
      special.clear()
      return
    }
    let rect = videoRect
    if time < lastTime - 0.1 || time - lastTime > 1 { invalidatePlan() }
    if invalidated || rect != plannedRect || time < plannedAt - 20 || time - plannedAt > 50 {
      requestPlan(time: time, rect: rect)
    }
    lastTime = time
    var visible = Set<String>()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    special.render(
      time: time, size: rect.size,
      backingScale: window?.windowScene?.screen.scale ?? traitCollection.displayScale,
      opacity: Float(max(0.1, min(1, opacity))))
    special.root.position = rect.origin
    reportSpecial()
    for placement in plan
    where placement.item.time <= time && time - placement.item.time < placement.duration {
      guard visible.count < 150 else { break }
      let item = placement.item
      visible.insert(item.id)
      let textLayer: CALayer
      if let cached = textLayers[item.id] {
        textLayer = cached
      } else {
        let glyphs = CALayer()
        glyphs.anchorPoint = .zero
        glyphs.contentsScale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        glyphs.bounds = CGRect(x: 0, y: 0, width: placement.width, height: placement.height)
        glyphs.contents = DanmakuTextBitmap.make(
          text: DanmakuLayout.displayText(item.text), fontSize: placement.fontSize,
          color: item.color, size: glyphs.bounds.size, scale: glyphs.contentsScale)
        layer.addSublayer(glyphs)
        textLayers[item.id] = glyphs
        textLayer = glyphs
      }
      let x = placement.x(at: time, viewportWidth: rect.width)
      textLayer.position = CGPoint(x: rect.minX + x, y: rect.minY + placement.y)
      textLayer.opacity = Float(max(0.1, min(1, opacity)))
    }
    for id in Array(textLayers.keys) where !visible.contains(id) {
      textLayers.removeValue(forKey: id)?.removeFromSuperlayer()
    }
    CATransaction.commit()
    let activeSpecial = special.compilation.scripts.contains {
      $0.item.time <= time && time < $0.item.time + $0.duration
    }
    link?.isPaused = !playing || (visible.isEmpty && !activeSpecial)
    wakeTask?.cancel()
    wakeTask = nil
    if playing && visible.isEmpty && !activeSpecial {
      let nextNormal = items.first(where: { $0.time > time && options.accepts($0) })?.time
      let nextSpecial = special.compilation.scripts.lazy.map(\.item.time).filter { $0 > time }.min()
      guard let next = [nextNormal, nextSpecial].compactMap({ $0 }).min() else { return }
      let delay = min(60, max(0.01, (next - time) / Double(max(0.1, player?.rate ?? 1))))
      wakeTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        guard let self else { return }
        self.tick()
      }
    }
  }
  func stop() {
    link?.invalidate()
    link = nil
    planTask?.cancel(); planTask = nil
    invalidated = true
    wakeTask?.cancel()
    wakeTask = nil
    clearLayers()
    special.clear()
  }
  isolated deinit {
    if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    wakeTask?.cancel()
    specialTask?.cancel()
    planTask?.cancel()
  }
}
