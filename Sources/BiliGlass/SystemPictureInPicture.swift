import AVKit
import SwiftUI

@MainActor @Observable final class SystemPictureInPicture: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
  // AVKit uses the same layer that presents video in the app.
  @ObservationIgnored let videoLayer = AVPlayerLayer()
  @ObservationIgnored private var controller: AVPictureInPictureController?
  @ObservationIgnored private var possibility: NSKeyValueObservation?
  private(set) var isPossible = false
  private(set) var isPresented = false
  var isActive: Bool { controller?.isPictureInPictureActive == true }
  private var prepared = false
  private var stopOnStart = false
  private var restore: (() -> Void)?
  private var onFailure: (() -> Void)?

  override init() {
    super.init()
    videoLayer.videoGravity = .resizeAspect
    videoLayer.preferredDynamicRange = .high
  }

  func prepare() {
    guard !prepared else { return }
    prepared = true
    guard AVPictureInPictureController.isPictureInPictureSupported(),
      let controller = AVPictureInPictureController(playerLayer: videoLayer) else { return }
    self.controller = controller
    controller.delegate = self
    possibility = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.isPossible = self.controller?.isPictureInPicturePossible == true
      }
    }
  }

  func toggle(restore: @escaping () -> Void, onFailure: @escaping () -> Void) {
    if isPresented { stop(); return }
    guard let controller, controller.isPictureInPicturePossible else { return }
    self.restore = restore
    self.onFailure = onFailure
    isPresented = true
    controller.startPictureInPicture()
  }

  func stop() {
    guard isPresented, let controller else { return }
    if isActive { controller.stopPictureInPicture() }
    else { stopOnStart = true }
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    if stopOnStart { controller.stopPictureInPicture() }
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    finish()
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    if !stopOnStart { onFailure?() }
    finish()
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    restore?()
    completionHandler(true)
  }

  private func finish() {
    isPresented = false
    stopOnStart = false
    restore = nil
    onFailure = nil
    if videoLayer.superlayer == nil { videoLayer.player = nil }
  }
}
