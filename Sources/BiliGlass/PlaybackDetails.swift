import AVKit
import SwiftUI

struct PlaybackStatusOverlay: View {
  let playback: Playback
  @State private var showsBuffering = false
  var body: some View {
    Group {
      if playback.loading || (playback.buffering && showsBuffering) {
        VStack(spacing: 10) {
          ProgressView().controlSize(.small)
          Text(playback.loading ? playback.loadingMessage : "缓冲中…").font(.callout)
        }.padding(.horizontal, 22).padding(.vertical, 18)
          .glassEffect(.regular, in: .rect(cornerRadius: 20)).colorScheme(.dark)
          .allowsHitTesting(false)
      }
    }.task(id: playback.buffering) {
      showsBuffering = false
      guard playback.buffering else { return }
      do {
        try await Task.sleep(for: .milliseconds(450))
        try Task.checkCancellation()
        showsBuffering = playback.buffering
      } catch { }
    }
  }
}
/// An in-player inspector, never a modal sheet: controls and the media clock remain active.
struct PlaybackDetailsOverlay: View {
  @Bindable var playback: Playback
  var topInset: CGFloat = 12
  var bottomInset: CGFloat = 12
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    GeometryReader { geometry in
      if playback.showsDetails {
        PlaybackDetails(playback: playback)
          .frame(width: min(370, max(200, geometry.size.width - 24)))
          .frame(height: max(120, min(playback.isOffline ? 200 : 470, geometry.size.height - topInset - bottomInset)))
          .padding(.top, topInset).padding(.trailing, 12)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .transition(.opacity)
      }
    }.animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: playback.showsDetails)
  }
}
struct PlaybackDetails: View {
  @Bindable var playback: Playback
  @State private var network: [String: Int] = [:]
  @State private var concurrency: [String: Int] = [:]
  @State private var copied = false
  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Label("播放详情", systemImage: "waveform.path.ecg").font(.headline)
        Spacer()
        Button { playback.showsDetails = false } label: { Image(systemName: "xmark") }
          .buttonStyle(.glass).accessibilityLabel("关闭播放详情").help("关闭播放详情")
      }
      Divider()
      ScrollView {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          VStack(spacing: 9) {
            row("状态", playback.error != nil ? "播放失败" : playback.loading ? playback.loadingMessage : playback.buffering ? "缓冲中" : playback.player.rate == 0 ? "已暂停" : "播放中")
            row("来源", playback.isOffline ? "本地缓存" : "在线流式播放")
            row("分辨率", playback.actualSize.isEmpty ? "等待画面" : playback.actualSize)
            row("视频编码", playback.decodedFormat.isEmpty ? playback.routeDiagnostics["codec"] ?? "—" : playback.decodedFormat)
            if !playback.isOffline {
              row("音频编码", playback.routeDiagnostics["audioCodec"] ?? "—")
              row("帧率", (Double(playback.routeDiagnostics["frameRate"] ?? "").map { String(format: "%.2f fps", $0) }) ?? "—")
              row("视频 / 音频码率", bitrate(playback.routeDiagnostics["videoBitrate"]) + " / " + bitrate(playback.routeDiagnostics["audioBitrate"]))
              Divider().padding(.vertical, 3)
              row("视频 CDN", playback.routeDiagnostics["videoHost"] ?? "正在选择")
              row("音频 CDN", playback.routeDiagnostics["audioHost"] ?? "正在选择")
              row("试读耗时", "\(playback.routeDiagnostics["videoProbeMS"] ?? "—") / \(playback.routeDiagnostics["audioProbeMS"] ?? "—") ms")
              row("视频下载速度", speed(network["videoBytesPerSecond"] ?? 0))
              row("音频下载速度", speed(network["audioBytesPerSecond"] ?? 0))
              row("前向缓冲", String(format: "%.1f 秒", bufferedSeconds))
              row("并发 · 当前 / 上限", "\(concurrency["activeVideoRequests"] ?? 0) / \(concurrency["effectiveConnections"] ?? 0)")
              row("设置上限 / 峰值", "\(concurrency["configuredConnections"] ?? 0) / \(concurrency["peakVideoRequests"] ?? 0)")
              row("视频线路切换", "\(playback.routeDiagnostics["videoSwitches"] ?? "0") 次")
              if let cached = concurrency["diskCacheBytes"] {
                row("临时磁盘缓存", ByteCountFormatter.string(fromByteCount: Int64(cached), countStyle: .file))
                row("预读状态", concurrency["diskCacheLimited"] == 1 ? "空间上限 · 按需播放" : concurrency["diskCacheComplete"] == 1 ? "已缓存到片尾" : "继续预读中")
              }
              row("分块补传", "\(concurrency["retriedBlocks"] ?? 0) 次")
              if let time = playback.startupMilliseconds["playing"] { row("本次起播", String(format: "%.2f 秒", Double(time) / 1000)) }
              row("丢帧", "\(playback.player.currentItem?.accessLog()?.events.last?.numberOfDroppedVideoFrames ?? 0)")
            }
            row("BV / CID", "\(playback.detail?.video.bvid ?? "—") / \(playback.selectedCID)")
            if !playback.isOffline {
              Text("码率来自视频描述；下载速度取最近 3 秒，缓冲充足时可为 0。")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if !playback.failureCode.isEmpty { row("错误代码", playback.failureCode) }
            if let available = playback.routeDiagnostics["manifest.video.available"] {
              row("可用视频流", available)
              row("可用音频流", playback.routeDiagnostics["manifest.audio.available"] ?? "—")
            }
          }.padding(.trailing, 3)
        }
      }.scrollIndicators(.automatic)
      Button(copied ? "已复制诊断信息" : "复制播放诊断") {
        Task {
          let report = await playback.diagnosticReport()
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(report, forType: .string)
          copied = true
        }
      }.buttonStyle(.glass).help("包含版本、播放阶段和线路错误；不包含登录凭据或完整媒体地址")
    }.padding(14)
      .background(.black.opacity(0.38), in: .rect(cornerRadius: 18))
      .background { Color.clear.glassEffect(.clear, in: .rect(cornerRadius: 18)) }
      .colorScheme(.dark).tint(.white)
      .task {
        while !Task.isCancelled {
          network = await playback.networkStats(); concurrency = await playback.transferStats()
          do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
      }
  }
  private var bufferedSeconds: Double {
    let time = playback.player.currentTime().seconds
    guard time.isFinite else { return 0 }
    return playback.player.currentItem?.loadedTimeRanges.map(\.timeRangeValue).filter {
      $0.start.seconds <= time + 0.5 && CMTimeRangeGetEnd($0).seconds >= time
    }.map { max(0, CMTimeRangeGetEnd($0).seconds - time) }.max() ?? 0
  }
  private func bitrate(_ string: String?) -> String {
    guard let value = string.flatMap(Double.init), value > 0 else { return "—" }
    return String(format: "%.0f Kbps", value / 1000)
  }
  private func speed(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + "/s" }
  private func row(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(title).foregroundStyle(.secondary).frame(width: 94, alignment: .leading)
      Text(value).monospacedDigit().textSelection(.enabled).frame(maxWidth: .infinity, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
    }.font(.caption)
  }
}
