import AVFoundation
import CoreImage
import Vision

/// Optional, local person segmentation. Work stops with playback and is never sent
/// to a service. The alpha mask is applied only to the danmaku overlay.
actor PersonMaskWorker {
  private let request = VNGeneratePersonSegmentationRequest()
  private let context = CIContext(options: [.cacheIntermediates: false])
  init() { request.qualityLevel = .balanced; request.outputPixelFormat = kCVPixelFormatType_OneComponent8 }
  func mask(_ buffer: CVPixelBuffer) throws -> CGImage? {
    try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
    guard let result = request.results?.first else { return nil }
    let person = CIImage(cvPixelBuffer: result.pixelBuffer)
    let extent = person.extent
    let clear = CIImage(color: .clear).cropped(to: extent)
    let white = CIImage(color: .white).cropped(to: extent)
    let inverse = clear.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: white, kCIInputMaskImageKey: person])
    return context.createCGImage(inverse, from: extent)
  }
}
@MainActor final class PersonAvoidance {
  private weak var view: NativeVideoView?
  private weak var player: AVPlayer?
  private weak var item: AVPlayerItem?
  private var output: AVPlayerItemVideoOutput?
  private let worker = PersonMaskWorker()
  private var task: Task<Void, Never>?
  private var observer: NSObjectProtocol?
  private var rate: NSKeyValueObservation?
  private var currentItem: NSKeyValueObservation?
  private var token = UUID()
  private var enabled = false
  private var latestMask: CGImage?
  private(set) var processedFrames = 0
  var statistics: [String: Any] { ["enabled": enabled, "processedFrames": processedFrames, "maskApplied": view?.danmaku.layer?.mask != nil, "running": task != nil] }
  init() {
    observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.enabled != UserDefaults.standard.bool(forKey: "danmakuPersonAvoidance") else { return }
        self.configure()
      }
    }
  }
  func attach(_ view: NativeVideoView, player: AVPlayer) {
    if self.view !== view { self.view?.danmaku.layer?.mask = nil; self.view = view }
    view.onVideoLayout = { [weak self, weak view] in if let self, let view, self.enabled { self.apply(self.latestMask, to: view) } }
    if self.player !== player {
      self.player = player
      rate = player.observe(\.rate) { [weak self] _, _ in Task { @MainActor in self?.configure() } }
      currentItem = player.observe(\.currentItem) { [weak self] _, _ in Task { @MainActor in self?.configure() } }
      configure()
    } else if enabled, task == nil { configure() }
  }
  private func configure() {
    task?.cancel(); task = nil; token = UUID()
    enabled = UserDefaults.standard.bool(forKey: "danmakuPersonAvoidance")
    guard let player, let view, view.isPlaybackSurfaceActive, enabled, let current = player.currentItem else {
      detachOutput(); latestMask = nil; self.view?.danmaku.layer?.mask = nil; return
    }
    if item !== current {
      detachOutput(); item = current
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
      current.add(output); self.output = output
    }
    let generation = token
    task = Task { [weak self] in
      guard let self else { return }
      repeat {
        guard generation == token, !Task.isCancelled, let target = self.view, !target.isHidden,
          let output, item === player.currentItem else { return }
        let time = player.currentTime()
        if output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
          do {
            let image = try await worker.mask(buffer)
            guard generation == token, !Task.isCancelled, self.view === target else { return }
            processedFrames += 1; latestMask = image; apply(image, to: target)
          } catch { target.danmaku.layer?.mask = nil }
        }
        if player.rate == 0 { break }
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      } while true
      if generation == token { task = nil }
    }
  }
  private func apply(_ image: CGImage?, to view: NativeVideoView) {
    guard let image, let layer = view.danmaku.layer else { layerClear(); return }
    // NativeVideoView already fits the danmaku view to the video, including
    // letterboxing. Using AVPlayerView.videoBounds here would apply that twice.
    guard view.danmaku.bounds.width > 0 else { return }
    let mask = CALayer(); mask.frame = view.danmaku.bounds; mask.contents = image
    CATransaction.begin(); CATransaction.setDisableActions(true); layer.mask = mask; CATransaction.commit()
  }
  private func layerClear() { view?.danmaku.layer?.mask = nil }
  private func detachOutput() { if let output { item?.remove(output) }; output = nil; item = nil }
  func stop() { task?.cancel(); task = nil; token = UUID(); detachOutput(); latestMask = nil; layerClear() }
  isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; task?.cancel(); if let output { item?.remove(output) } }
}
