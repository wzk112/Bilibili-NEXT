import AVKit
import BiliModels
import BiliNetworking
import BiliPlayback
import SwiftUI

struct PlaybackResume {
  let position: Double
  var playing: Bool
}

@MainActor @Observable final class Playback {
  let player = AVPlayer()
  #if os(macOS)
  @ObservationIgnored let specialDanmakuCache = SpecialDanmakuCache()
  @ObservationIgnored let personAvoidance = PersonAvoidance()
  @ObservationIgnored weak var nativeView: NativeVideoView?
  #endif
  private var bridge = DASHToHLSBridge()
  private var videoTransport: ParallelVideoStream?
  private var diskCache: PlaybackDiskCache?
  private var cdnTransport: CDNTransport?
  private var mediaConnectionPool: HTTPRangeStreamingClient?
  var detail: Detail?
  var streams: Streams?
  var selectedCID = 0
  var selectedQuality = 0
  var loading = false
  var loadingMessage = "准备播放"
  var recoveryNotice: String?
  var error: String?
  var actualSize = ""
  var sourceFormat = ""
  var decodedFormat = ""
  var renderedFrame = false
  var buffering = false
  var positionSeconds = 0.0
  var durationSeconds = 0.0
  var isPlaying = false
  private var lastControlTime = -1.0
  private var lastSavedTime = -1.0
  var failureCode = ""
  private(set) var routeDiagnostics: [String: String] = [:]
  private(set) var startupMilliseconds: [String: Int] = [:]
  var speed: Float = 1
  var isBoosting = false
  var temporarySpeed: Float = 3
  var showsDetails = false
  var showsSystemControls = false
  var isFullscreen = false
  var boostLabel: String { "\(Double(temporarySpeed).formatted())× 临时倍速" + (isOffline ? "" : " · 在线播放") }
  var isOffline = false
  var persistQualityPreference = true
  var connectionOverride: Int?
  var localDanmaku: URL?
  private(set) var generation = UUID()
  private(set) var pendingResume: PlaybackResume?
  private(set) var requestedQuality: Int?
  private var task: Task<Void, Never>?
  private var stallMonitor: Task<Void, Never>?
  private var automaticRecoveries = 0
  private var watchdog: Task<Void, Never>?
  private var requestedBVID: String?
  private var localURL: URL?
  private var asset: PreparedPlaybackAsset?
  private var statusObservation: NSKeyValueObservation?
  private var sizeObservation: NSKeyValueObservation?
  private var timeObserver: Any?
  private var controlObservation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  var onProgress: ((String, Int, Double, Bool) -> Void)?
  var onEnded: (() -> Void)?
  func seek(to seconds: Double) {
    guard seconds.isFinite, seconds >= 0 else { return }
    player.seek(to: CMTime(seconds: min(seconds, max(0, durationSeconds)), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  }
  func focusPlayer() {
    #if os(macOS)
    DispatchQueue.main.async { [weak self] in
      guard let view = self?.nativeView, !view.isHidden, let window = view.window, window.attachedSheet == nil else { return }
      window.makeFirstResponder(view)
    }
    #endif
  }
  func pausePlayback() {
    pendingResume?.playing = false
    player.pause()
    saveCurrentProgress()
  }
  func continuePlayback() {
    if pendingResume != nil {
      pendingResume?.playing = true
      if player.currentItem?.status == .readyToPlay { player.playImmediately(atRate: speed) }
    } else if player.rate == 0 { togglePlayback() }
  }
  func togglePlayback() {
    if pendingResume != nil {
      pendingResume?.playing.toggle()
      if pendingResume?.playing == true, player.currentItem?.status == .readyToPlay {
        player.playImmediately(atRate: speed)
      } else { player.pause() }
      return
    }
    guard player.currentItem != nil else { return }
    if player.rate != 0 { player.pause(); saveCurrentProgress(); return }
    let duration = player.currentItem?.duration.seconds ?? 0
    let current = player.currentTime().seconds
    if duration.isFinite, duration > 0, current.isFinite, current >= duration - 0.25 {
      let token = generation
      player.seek(to: .zero) { [weak self] finished in
        Task { @MainActor in
          guard let self, finished, token == self.generation else { return }
          self.player.playImmediately(atRate: self.speed)
        }
      }
    } else { player.playImmediately(atRate: speed) }
  }
  init() {
    player.preventsDisplaySleepDuringVideoPlayback = true
    endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
      MainActor.assumeIsolated {
        guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
        self.saveCurrentProgress(); self.onEnded?()
      }
    }
    controlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor in
        guard let self else { return }
        self.buffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        self.isPlaying = self.player.rate != 0
      }
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self, self.pendingResume == nil, time.seconds.isFinite else { return }
        if abs(time.seconds - self.lastControlTime) >= 0.01 {
          self.lastControlTime = time.seconds
          self.positionSeconds = max(0, time.seconds)
        }
        let duration = self.player.currentItem?.duration.seconds ?? 0
        if duration.isFinite, duration > 0, duration != self.durationSeconds { self.durationSeconds = duration }
        if let d = self.detail, abs(time.seconds - self.lastSavedTime) >= 5 {
          self.lastSavedTime = time.seconds
          self.onProgress?(d.video.bvid, self.selectedCID, time.seconds, false)
        }
      }
    }
  }
  nonisolated static func restoredPosition(_ saved: Double, duration: Int) -> Double {
    guard saved.isFinite, saved > 0 else { return 0 }
    guard duration > 0 else { return saved }
    // Do not start a completed episode inside the final, potentially audio-only DASH segment.
    let endMargin = min(10, Double(duration) * 0.1)
    return saved >= Double(duration) - endMargin ? 0 : saved
  }
  func open(_ bvid: String, api: API, quality: Int? = nil, initialCID: Int? = nil, restoring: PlaybackResume? = nil, resume: @escaping (Int) -> Double) {
    stop()
    automaticRecoveries = 0
    let token = generation
    loading = true
    detail = nil
    requestedBVID = bvid
    localURL = nil
    selectedQuality = 0
    streams = nil
    isOffline = false
    task = Task {
      do {
        let d = try await api.detail(bvid)
        try Task.checkCancellation()
        guard token == generation else { return }
        detail = d
        guard let page = d.pages.first(where: { $0.id == initialCID }) ?? d.pages.first else { throw BiliError(text: "没有可用分集") }
        selectedCID = page.id
        try await load(
          api: api, bvid: bvid, cid: page.id, quality: quality,
          position: restoring?.position ?? Self.restoredPosition((UserDefaults.standard.object(forKey: "rememberPosition") as? Bool ?? true) ? resume(page.id) : 0, duration: page.duration > 0 ? page.duration : d.pages.count == 1 ? d.video.duration : 0),
          playing: restoring?.playing ?? (UserDefaults.standard.object(forKey: "autoPlay") as? Bool ?? true), token: token)
      } catch { fail(error, token: token) }
    }
  }
  func selectPage(_ cid: Int, api: API, resume: Double) {
    guard let d = detail else { return }
    beginChange()
    selectedCID = cid
    selectedQuality = 0
    streams = nil
    let token = generation
    task = Task {
      do {
        try await load(
          api: api, bvid: d.video.bvid, cid: cid, quality: nil,
          position: Self.restoredPosition(resume, duration: d.pages.first(where: { $0.id == cid })?.duration ?? 0), playing: true,
          token: token)
      } catch { fail(error, token: token) }
    }
  }
  func selectQuality(_ qn: Int, api: API, force: Bool = false) {
    guard let d = detail, !isOffline,
      force || qn != (requestedQuality ?? selectedQuality) || error != nil else { return }
    // The old item is already detached during a switch. Keep its position and
    // playback intent if another quality (or retry) supersedes that request.
    let time = player.currentTime().seconds
    let resume = pendingResume ?? PlaybackResume(
      position: max(0, time.isFinite ? time : positionSeconds),
      playing: player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
    beginChange()
    pendingResume = resume
    requestedQuality = qn
    positionSeconds = resume.position
    let token = generation
    let cid = selectedCID
    task = Task {
      do {
        try await load(
          api: api, bvid: d.video.bvid, cid: cid, quality: qn, position: resume.position,
          playing: resume.playing, token: token)
      } catch { fail(error, token: token) }
    }
  }
  private func load(
    api: API, bvid: String, cid: Int, quality: Int?, position: Double, playing: Bool, token: UUID
  ) async throws {
    try Task.checkCancellation()
    guard token == generation else { throw CancellationError() }
    if pendingResume == nil { pendingResume = PlaybackResume(position: position, playing: playing) }
    positionSeconds = position
    let loadStarted = ContinuousClock.now
    func elapsed() -> Int {
      let d = loadStarted.duration(to: .now).components
      return Int(d.seconds * 1_000 + d.attoseconds / 1_000_000_000_000_000)
    }
    loadingMessage = "正在获取播放地址"
    // Refresh signed CDN URLs for every load. Never persist a playurl response.
    let s = try await api.streams(bvid: bvid, cid: cid)
    try Task.checkCancellation()
    guard token == generation else { return }
    routeDiagnostics = s.diagnostics
    startupMilliseconds["playurl"] = elapsed()
    let preferred = UserDefaults.standard.integer(forKey: "quality")
    let qn =
      quality ?? (s.videos.contains { $0.id == preferred } ? preferred : s.videos.first?.id ?? 0)
    requestedQuality = qn
    guard let original = API.bestVideo(s.videos, quality: qn) else {
      throw BiliError(text: "此清晰度已不可用，请重试")
    }
    streams = s
    let connections = connectionOverride ?? (UserDefaults.standard.object(forKey: "videoThreads") as? Int ?? 4)
    // Keep established HTTPS connections across quality changes, but create fresh
    // route/prefix state from the newly fetched signed URLs on every load.
    let pool = mediaConnectionPool ?? HTTPRangeStreamingClient(maximumConnectionsPerHost: 32)
    mediaConnectionPool = pool
    let cdn = CDNTransport(source: pool)
    cdnTransport = cdn
    let videoURLs = Set(s.videos.flatMap(\.urlCandidates))
    let cache = (UserDefaults.standard.object(forKey: "continuousPreload") as? Bool ?? true)
      ? try? PlaybackDiskCache(source: cdn, videoURLs: videoURLs, connections: connections,
          capacity: Int64(max(1, min(32, UserDefaults.standard.object(forKey: "preloadDiskGB") as? Int ?? 8))) * 1_073_741_824,
          streamDuringStartup: true) : nil
    diskCache = cache
    let transport = ParallelVideoStream(
      connections: connections, videoURLs: videoURLs, source: cache ?? cdn as any HTTPRangeStreaming, startup: true)
    videoTransport = transport
    bridge = DASHToHLSBridge(mediaStreamer: transport)
    let others = API.videoCandidates(s.videos, quality: qn).filter { $0.codecs != original.codecs }
    var candidates = [original] + others
    // A refreshed session also gives a transient network failure a second chance.
    if candidates.count == 1 { candidates.append(original) }
    var lastError: Error = BiliError(text: "无法开始播放")
    for (index, candidate) in candidates.prefix(3).enumerated() {
      try Task.checkCancellation()
      guard token == generation else { return }
      releaseItem()
      loading = true
      error = nil
      failureCode = ""
      loadingMessage = index == 0 ? "正在选择播放线路" : "正在尝试备用播放源（\(index + 1)）"
      do {
        let fresh =
          index > 0 && candidate.codecs == original.codecs
          ? try await api.streams(bvid: bvid, cid: cid) : s
        let source =
          fresh.videos.first { $0.id == qn && $0.codecs == candidate.codecs } ?? candidate
        async let selectedVideo = cdn.select(source, headers: API.mediaHeaders)
        async let selectedAudio = cdn.select(fresh.audio, headers: API.mediaHeaders)
        let (videoRoute, audioRoute) = try await (selectedVideo, selectedAudio)
        try Task.checkCancellation()
        guard token == generation else { return }
        routeDiagnostics = fresh.diagnostics.merging([
          "videoHost": videoRoute.host, "audioHost": audioRoute.host,
          "videoProbeMS": String(videoRoute.milliseconds), "audioProbeMS": String(audioRoute.milliseconds),
          "videoCandidates": String(videoRoute.candidateCount), "audioCandidates": String(audioRoute.candidateCount),
          "attempt": String(index + 1), "codec": source.codecs,
          "videoBitrate": String(source.bandwidth ?? 0), "audioBitrate": String(fresh.audio.bandwidth ?? 0),
          "audioCodec": fresh.audio.codecs, "frameRate": String(source.videoAttributes?.frameRate ?? 0),
        ]) { _, current in current }
        startupMilliseconds["selected"] = elapsed()
        loadingMessage = "正在准备播放"
        let activeBridge = bridge
        let (video, prepared) = try await withDeadline(seconds: 10) {
          let video = try await VideoSignalling.inspect(
            videoRoute.representation, client: HTTPRangeClient(streamer: cdn)).0
          let prepared = try await activeBridge.prepare(
            video: video, audio: audioRoute.representation, headers: API.mediaHeaders,
            start: position > 0 ? position : nil)
          return (video, prepared)
        }
        guard !Task.isCancelled, token == generation else {
          prepared.stop()
          return
        }
        asset = prepared
        startupMilliseconds["prepared"] = elapsed()
        let codec =
          video.codecs.hasPrefix("avc1") ? "H.264" : video.codecs.hasPrefix("av01") ? "AV1" : "HEVC"
        sourceFormat = (video.id == 126 ? "杜比视界 · " : video.id == 125 ? "HDR · " : "") + codec
        selectedQuality = video.id
        // The playlist carries every SIDX segment and the resume position. Creating
        // a composition from a remote fragmented MP4 can freeze its duration at the
        // first fragment (often five seconds), truncating otherwise playable Dolby video.
        let item = AVPlayerItem(url: prepared.url)
        install(item, token: token, position: 0, playing: playing, managedStartup: true)
        loadingMessage = "正在缓冲画面"
        try await awaitStartup(item, token: token, playing: playing)
        try Task.checkCancellation()
        guard token == generation, player.currentItem === item else { throw CancellationError() }
        startupMilliseconds["playing"] = elapsed()
        await transport.finishStartup()
        await cache?.start()
        try Task.checkCancellation()
        guard token == generation, player.currentItem === item else { throw CancellationError() }
        item.preferredForwardBufferDuration = UserDefaults.standard.object(forKey: "bufferSeconds") as? Double ?? 15
        pendingResume = nil
        requestedQuality = nil
        loading = false
        error = nil
        if persistQualityPreference { UserDefaults.standard.set(video.id, forKey: "quality") }
        if index > 0 { recoveryNotice = "已恢复播放" }
        monitorStalls(api: api, token: token)
        return
      } catch {
        if Task.isCancelled || token != generation { throw CancellationError() }
        lastError = error
      }
    }
    releaseItem()
    throw BiliError(
      text: "视频暂时无法起播，已尝试其他播放源。可重试或切换清晰度。\n" + lastError.localizedDescription)
  }
  private func monitorStalls(api: API, token: UUID) {
    stallMonitor?.cancel()
    stallMonitor = Task { [weak self] in
      var waitingSince: ContinuousClock.Instant?
      var progress = PlaybackProgressDeadline()
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self, token == self.generation else { return }
        if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate || self.player.currentItem?.status == .failed {
          if waitingSince == nil { waitingSince = .now; progress = PlaybackProgressDeadline() }
          if let item = self.player.currentItem, item.status == .readyToPlay,
            self.player.rate > 0, let waitingStart = waitingSince, waitingStart.duration(to: .now) >= .seconds(1) {
            let time = self.player.currentTime().seconds
            let ranges = item.loadedTimeRanges.map { ($0.timeRangeValue.start.seconds, $0.timeRangeValue.duration.seconds) }
            let ahead = Self.bufferedAhead(time: time, ranges: ranges)
            // HLS throughput estimates include a slow repaired segment. On a fixed
            // quality this can leave AVPlayer waiting despite usable buffered media.
            // Resume only when there is a real contiguous buffer, never on bytes alone.
            if ahead >= max(2, Double(self.speed) * 2) {
              self.player.playImmediately(atRate: self.isBoosting ? self.temporarySpeed : self.speed)
              waitingSince = nil
              continue
            }
          }
          let bytes = await self.networkStats()["videoBytes"] ?? 0
          if let waitingSince, self.player.currentItem?.status == .failed || progress.expired(
            now: waitingSince.duration(to: .now), videoBytes: bytes,
            mediaTime: self.player.currentTime().seconds) {
            guard self.automaticRecoveries < 2 else {
              self.error = "网络持续缓冲，可重试或切换清晰度"
              return
            }
            self.automaticRecoveries += 1
            self.selectQuality(self.selectedQuality, api: api, force: true)
            return
          }
        } else {
          waitingSince = nil
        }
      }
    }
  }
  nonisolated static func bufferedAhead(time: Double, ranges: [(Double, Double)]) -> Double {
    guard time.isFinite, time >= 0 else { return 0 }
    // Adjacent fragmented audio/video ranges can start a few frames beyond the
    // stalled media clock. A larger real gap still requires fresh data.
    return ranges.filter { start, duration in start.isFinite && duration.isFinite && duration > 0 && start <= time + 0.2 && start + duration > time }
      .map { $0.0 + $0.1 - time }.max() ?? 0
  }
  private func awaitStartup(_ item: AVPlayerItem, token: UUID, playing: Bool) async throws {
    // Ready status alone is insufficient: some DASH streams never advance the media clock.
    let began = ContinuousClock.now
    var progress = PlaybackProgressDeadline()
    var initialTime: Double?
    while true {
      try Task.checkCancellation()
      guard generation == token, player.currentItem === item else { throw CancellationError() }
      if item.status == .failed {
        if let e = item.error as NSError? {
          failureCode = "\(e.domain) \(e.code)"
          throw e
        }
        throw BiliError(text: "系统播放器无法读取此视频流")
      }
      if item.status == .readyToPlay {
        let wantsPlayback = pendingResume?.playing ?? playing
        if !wantsPlayback && item.presentationSize.width > 0 { return }
        let time = player.currentTime().seconds
        if wantsPlayback, player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
          began.duration(to: .now) >= .seconds(1),
          Self.bufferedAhead(time: time, ranges: item.loadedTimeRanges.map {
            ($0.timeRangeValue.start.seconds, $0.timeRangeValue.duration.seconds)
          }) >= max(2, Double(speed) * 2) {
          // Startup precedes monitorStalls. A fixed-quality HLS item can wait on
          // its throughput estimate even after the requested position is buffered.
          player.playImmediately(atRate: speed)
        }
        if time.isFinite && player.timeControlStatus == .playing {
          if let initialTime, time > initialTime + 0.12, item.presentationSize.width > 0 { return }
          if initialTime == nil { initialTime = time }
        }
      }
      let bytes = await networkStats()["videoBytes"] ?? 0
      if progress.expired(now: began.duration(to: .now), videoBytes: bytes,
                          mediaTime: player.currentTime().seconds) { break }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw BiliError(text: "此线路没有返回可播放的数据")
  }
  private func releaseItem() {
    watchdog?.cancel()
    statusObservation = nil
    sizeObservation = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    asset?.stop()
    asset = nil
    renderedFrame = false
    actualSize = ""
    decodedFormat = ""
  }
  private func install(
    _ item: AVPlayerItem, token: UUID, position: Double, playing: Bool, managedStartup: Bool = false
  ) {
    watchdog?.cancel()
    if !managedStartup {
      watchdog = Task { [weak self] in
        try? await Task.sleep(for: .seconds(35))
        guard !Task.isCancelled, let self, self.generation == token, self.loading else { return }
        self.loading = false
        self.error = "无法读取本地视频，请检查文件是否完整"
      }
    }
    let preferredBuffer = UserDefaults.standard.object(forKey: "bufferSeconds") as? Double ?? 15
    item.audioTimePitchAlgorithm = .spectral
    item.preferredForwardBufferDuration = managedStartup ? min(3, preferredBuffer) : preferredBuffer
    player.replaceCurrentItem(with: item)
    var didStart = false
    statusObservation = item.observe(\.status, options: [.initial, .new]) {
      [weak self, weak item] _, _ in
      Task { @MainActor in
        guard let self, let item, self.generation == token, self.player.currentItem === item else {
          return
        }
        switch item.status {
        case .readyToPlay:
          if !didStart {
            didStart = true
            if position > 0 {
              await self.player.seek(
                to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero,
                toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600))
            }
            guard self.generation == token, self.player.currentItem === item else { return }
            self.watchdog?.cancel()
            let duration = item.duration.seconds
            if duration.isFinite, duration > 0 { self.durationSeconds = duration }
            if !managedStartup { self.loading = false }
            Task { await self.inspectFormat(item, token: token) }
            if self.pendingResume?.playing ?? playing { self.player.playImmediately(atRate: self.speed) }
          }
        case .failed:
          if !managedStartup { self.loading = false }
          self.watchdog?.cancel()
          if let e = item.error as NSError? { self.failureCode = "\(e.domain) \(e.code)" }
          if !managedStartup || !self.loading { self.error = "播放中断，请重试" }
        default: break
        }
      }
    }
    sizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) {
      [weak self] item, _ in
      let size = item.presentationSize
      Task { @MainActor in
        guard let self, self.generation == token, self.player.currentItem === item else { return }
        self.actualSize = size.width > 0 ? "\(Int(size.width)) × \(Int(size.height))" : ""
      }
    }

  }
  private func inspectFormat(_ item: AVPlayerItem, token: UUID) async {
    for _ in 0..<10 {
      guard token == generation, player.currentItem === item else { return }
      let tracks = item.tracks.compactMap(\.assetTrack)
      for track in tracks where track.mediaType == .video {
        if let descriptions = try? await track.load(.formatDescriptions),
          let format = descriptions.first
        {
          let type = CMFormatDescriptionGetMediaSubType(format)
          let bytes: [UInt8] = [
            UInt8((type >> 24) & 255), UInt8((type >> 16) & 255), UInt8((type >> 8) & 255),
            UInt8(type & 255),
          ]
          let codec = String(bytes: bytes, encoding: .ascii) ?? ""
          let transfer =
            CMFormatDescriptionGetExtension(
              format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String ?? ""
          guard token == generation else { return }
          decodedFormat = codec + (transfer.isEmpty ? "" : " · " + transfer)
          return
        }
      }
      try? await Task.sleep(for: .milliseconds(300))
    }
  }
  func openLocal(_ url: URL, video: Video, cid: Int = 0, sidecar: URL? = nil, restoring: PlaybackResume? = nil) {
    stop()
    detail = Detail(video: video, description: "", pages: [])
    streams = nil
    isOffline = true
    selectedCID = cid
    localDanmaku = sidecar
    localURL = url
    loading = true
    let token = generation
    loadingMessage = "正在读取缓存视频"
    task = Task {
      do {
        let compatible = try await MP4Compatibility.playbackURL(url)
        try Task.checkCancellation()
        guard token == generation else { return }
        let item = AVPlayerItem(url: compatible)
        install(item, token: token, position: restoring?.position ?? 0, playing: restoring?.playing ?? true, managedStartup: true)
        try await awaitStartup(item, token: token, playing: restoring?.playing ?? true)
        loading = false
        sourceFormat = "本地缓存"
      } catch {
        guard token == generation else { return }
        releaseItem()
        fail(error, token: token)
      }
    }
  }
  func retry(api: API) {
    if isOffline, let localURL, let d = detail {
      openLocal(localURL, video: d.video, cid: selectedCID, sidecar: localDanmaku)
      return
    }
    guard let d = detail else {
      if let requestedBVID { open(requestedBVID, api: api, resume: { _ in 0 }) }
      return
    }
    if let quality = requestedQuality ?? (selectedQuality != 0 ? selectedQuality : nil) {
      selectQuality(quality, api: api, force: true)
    } else {
      open(d.video.bvid, api: api, resume: { _ in 0 })
    }
  }
  func transferStats() async -> [String: Int] {
    guard let videoTransport else { return [:] }
    // Disk-cache permits measure network work; outer permits include cached reads.
    let stats = if loading { await videoTransport.statistics() }
      else if let diskCache { await diskCache.statistics() }
      else { await videoTransport.statistics() }
    return stats
  }
  func cdnAttempts() async -> [[String: String]] { await cdnTransport?.diagnostics() ?? [] }
  func diagnosticReport() async -> String {
    let report: [String: Any] = [
      "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
      "system": ProcessInfo.processInfo.operatingSystemVersionString,
      "bvid": detail?.video.bvid ?? requestedBVID ?? "", "cid": selectedCID,
      "quality": selectedQuality, "failureCode": failureCode, "stage": loadingMessage,
      "sources": routeDiagnostics, "probes": await cdnAttempts(),
      "startupMS": startupMilliseconds,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }
  func networkStats() async -> [String: Int] {
    guard let transport = cdnTransport else { return [:] }
    let stats = await transport.statistics()
    let hosts = await transport.activeHosts()
    if transport === cdnTransport { routeDiagnostics.merge(hosts) { _, current in current } }
    return stats
  }
  func setSpeed(_ rate: Float) {
    speed = rate
    if player.rate != 0 { player.rate = isBoosting ? temporarySpeed : rate }
  }
  func seekBy(_ offset: Double) {
    let now = player.currentTime().seconds
    let duration = player.currentItem?.duration.seconds ?? 0
    guard now.isFinite, duration.isFinite, duration > 0 else { return }
    player.seek(to: CMTime(seconds: min(duration, max(0, now + offset)), preferredTimescale: 600))
  }
  nonisolated static func temporaryRate(isOffline: Bool, canPlayFastForward: Bool) -> Float {
    // HLS may report fast-forward support but enter I-frame-only trick play above 2×.
    // Only complete local media uses 3×; a fully read-ahead HLS session is still HLS.
    isOffline && canPlayFastForward ? 3 : 2
  }
  func beginTemporarySpeed() -> Bool {
    guard !loading, !buffering, player.timeControlStatus == .playing, let item = player.currentItem else { return false }
    temporarySpeed = Self.temporaryRate(isOffline: isOffline, canPlayFastForward: item.canPlayFastForward)
    isBoosting = true
    player.rate = temporarySpeed
    return true
  }
  func endTemporarySpeed() {
    guard isBoosting else { return }
    isBoosting = false
    if player.rate != 0 { player.rate = speed }
  }
  private func fail(_ e: Error, token: UUID) {
    guard token == generation, !(e is CancellationError) else { return }
    loading = false
    if let manifest = e as? StreamManifestError {
      routeDiagnostics = manifest.diagnostics
      failureCode = "MEDIA_MANIFEST_" + manifest.kind.uppercased()
    } else if let urlError = e as? URLError {
      failureCode = "NSURLErrorDomain \(urlError.code.rawValue)"
    } else if let code = (e as? BiliError)?.code {
      failureCode = "API \(code)"
    }
    error = e.localizedDescription
  }
  func saveCurrentProgress() {
    guard pendingResume == nil, let detail, player.currentItem != nil else { return }
    let seconds = player.currentTime().seconds
    guard seconds.isFinite, seconds > 0 else { return }
    onProgress?(detail.video.bvid, selectedCID, seconds, true)
  }
  private func beginChange() {
    showsSystemControls = false
    saveCurrentProgress()
    endTemporarySpeed()
    task?.cancel()
    stallMonitor?.cancel()
    watchdog?.cancel()
    renderedFrame = false
    buffering = false
    failureCode = ""
    generation = UUID()
    pendingResume = nil
    requestedQuality = nil
    lastControlTime = -1; lastSavedTime = -1; positionSeconds = 0; durationSeconds = 0; isPlaying = false
    statusObservation = nil
    sizeObservation = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    asset?.stop()
    asset = nil
    error = nil
    recoveryNotice = nil
    loadingMessage = "准备播放"
    actualSize = ""
    sourceFormat = ""
    decodedFormat = ""
    loading = true
    routeDiagnostics = [:]
    startupMilliseconds = [:]
    cdnTransport = nil
    if let cache = diskCache { Task { await cache.stop() } }
    diskCache = nil
    videoTransport = nil
    bridge = DASHToHLSBridge()
  }
  func stop() {
    showsSystemControls = false
    #if os(macOS)
    personAvoidance.stop()
    #endif
    beginChange()
    mediaConnectionPool = nil
    loading = false
  }
  isolated deinit {
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    task?.cancel()
    stallMonitor?.cancel()
    asset?.stop()
    if let cache = diskCache { Task { await cache.stop() } }
    if let timeObserver { player.removeTimeObserver(timeObserver) }
  }
}

#if os(macOS)
@MainActor final class NativeVideoView: AVPlayerView, @preconcurrency AVPlayerViewPictureInPictureDelegate {
  let danmaku = DanmakuView(frame: .zero)
  var toggleFullscreen: (() -> Void)?
  var togglePlayback: (() -> Void)?
  var keyboard: PlayerKeyboard?
  var onVideoLayout: (() -> Void)?
  var onPictureInPicture: (() -> Void)?
  private var wheelMonitor: Any?
  override init(frame: NSRect) {
    super.init(frame: frame)
    pictureInPictureDelegate = self
    let doubleClick = NSClickGestureRecognizer(target:self,action:#selector(toggleByDoubleClick(_:)))
    doubleClick.numberOfClicksRequired = 2
    addGestureRecognizer(doubleClick)
  }
  @objc private func toggleByDoubleClick(_ gesture:NSClickGestureRecognizer) { toggleFullscreen?() }
  func playerViewDidStartPicture(inPicture playerView: AVPlayerView) { onPictureInPicture?() }
  func playerViewDidStopPicture(inPicture playerView: AVPlayerView) { onPictureInPicture?() }
  func playerViewShouldAutomaticallyDismissAtPicture(inPictureStart playerView: AVPlayerView) -> Bool { false }
  func playerView(_ playerView: AVPlayerView, failedToStartPictureInPictureWithError error: Error) { onPictureInPicture?() }
  func playerView(_ playerView: AVPlayerView, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: (Bool) -> Void) { completionHandler(true) }
  func attachDanmaku() {
    guard let overlay = contentOverlayView else { return }
    if danmaku.superview !== overlay { overlay.addSubview(danmaku) }
    danmaku.autoresizingMask = [.width, .height]
    // AVKit can report an empty videoBounds even while its overlay has a valid size.
    // The overlay is already aligned with the rendered video by AVKit.
    let presentation = player?.currentItem?.presentationSize ?? .zero
    danmaku.frame = presentation.width > 0 && presentation.height > 0
      ? AVMakeRect(aspectRatio: presentation, insideRect: overlay.bounds) : overlay.bounds
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let wheelMonitor {
      NSEvent.removeMonitor(wheelMonitor)
      self.wheelMonitor = nil
    }
    guard let window else { keyboard?.cancelHeldKey(); return }
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, self.window === window, !self.isHidden, window?.attachedSheet == nil else { return }
      window?.makeFirstResponder(self)
    }
    wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      let handled = MainActor.assumeIsolated {
        guard let self, event.window === self.window, !self.isHidden,
          self.visibleRect.contains(self.convert(event.locationInWindow, from: nil))
        else { return false }
        // AVPlayerView consumes wheel gestures as seeks. Route them to the page before
        // either the player or its private timeline controls can handle the event.
        self.enclosingScrollView?.scrollWheel(with: event)
        return true
      }
      return handled ? nil : event
    }
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
  }
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) {
    guard let player else { return }
    switch event.keyCode {
    case 49: togglePlayback?()
    case 123, 124:
      let current = player.currentTime().seconds
      let duration = player.currentItem?.duration.seconds ?? 0
      if current.isFinite, duration.isFinite { player.seek(to:CMTime(seconds:min(duration,max(0,current+(event.keyCode == 123 ? -5:5))),preferredTimescale:600)) }
    default: super.keyDown(with:event)
    }
  }
  override func scrollWheel(with event: NSEvent) {
    enclosingScrollView?.scrollWheel(with: event)
  }
  isolated deinit { if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) } }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    attachDanmaku()
    onVideoLayout?()
  }
}
struct NativePlayer: NSViewRepresentable {
  let playback: Playback
  let items: [Danmaku]
  let enabled: Bool
  var showsNativeControls = false
  var fullscreen = false
  var toggleFullscreen: (() -> Void)?
  class Coordinator { var observation: NSKeyValueObservation? }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NativeVideoView {
    let v = NativeVideoView(frame: .zero)
    v.player = playback.player
    v.danmaku.compilationCache = playback.specialDanmakuCache
    playback.nativeView = v
    v.toggleFullscreen = toggleFullscreen
    v.togglePlayback = { [weak playback] in playback?.togglePlayback() }
    v.onPictureInPicture = { [weak playback] in playback?.showsSystemControls = false }
    v.keyboard = PlayerKeyboard(view: v, playback: playback)
    v.attachDanmaku()
    v.controlsStyle = showsNativeControls ? .floating : .none
    v.showsFullScreenToggleButton = false
    v.allowsPictureInPicturePlayback = true
    v.allowsVideoFrameAnalysis = false
    v.videoGravity = .resizeAspect
    v.preferredDisplayDynamicRange = .high
    context.coordinator.observation = v.observe(\.isReadyForDisplay, options: [.initial, .new]) {
      view, _ in
      let ready = view.isReadyForDisplay
      Task { @MainActor [weak view] in
        view?.attachDanmaku()
        if view === playback.nativeView { playback.renderedFrame = ready }
      }
    }
    return v
  }
  func updateNSView(_ view: NativeVideoView, context: Context) {
    view.controlsStyle = (showsNativeControls || playback.showsSystemControls) ? .floating : .none
    let active = !playback.isFullscreen || fullscreen
    let wasHidden = view.isHidden
    view.isHidden = !active
    if active && wasHidden { playback.focusPlayer() }
    if !active { view.keyboard?.cancelHeldKey(); view.player = nil; view.danmaku.player = nil; return }
    playback.nativeView = view
    if view.player !== playback.player { view.player = playback.player }
    view.toggleFullscreen = toggleFullscreen
    view.danmaku.topInset = fullscreen ? 76 : 12
    view.danmaku.bottomInset = fullscreen ? 100 : 12
    view.attachDanmaku()
    view.danmaku.player = playback.player
    if view.danmaku.items != items {
      view.danmaku.items = items
    }
    view.danmaku.enabled = enabled
    view.danmaku.isHidden = !enabled
    view.needsLayout = true
    playback.personAvoidance.attach(view, player: playback.player)
  }
  static func dismantleNSView(_ view: NativeVideoView, coordinator: Coordinator) {
    view.keyboard?.stop()
    view.keyboard = nil
    coordinator.observation = nil
    view.danmaku.player = nil
    view.player = nil
  }
}

#endif
