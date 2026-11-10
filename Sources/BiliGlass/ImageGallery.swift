import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ImageGalleryTarget: Identifiable {
  let id = UUID()
  let urls: [String]
  let selected: Int
}
struct ImageGallery: View {
  let target: ImageGalleryTarget
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var index = 0
  @State private var image: NSImage?
  @State private var original: Data?
  @State private var error: String?
  @State private var zoom = 1.0
  @State private var saved = false
  @State private var loading = true
  private var address: String { target.urls.indices.contains(index) ? target.urls[index] : "" }
  var body: some View {
    VStack(spacing:16) {
      HStack(spacing:14) {
        Text("图片 \(index+1) / \(target.urls.count)").font(.headline)
        Spacer()
        Button { change(-1) } label: { Image(systemName:"chevron.left") }.disabled(index == 0).help("上一张").keyboardShortcut(.leftArrow,modifiers:[])
        Button { change(1) } label: { Image(systemName:"chevron.right") }.disabled(index+1 >= target.urls.count).help("下一张").keyboardShortcut(.rightArrow,modifiers:[])
        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
      }.buttonStyle(.appGlassButton)
      ZStack {
        Color.black.opacity(0.2)
        if let image {
          NativeImageCanvas(image:image,zoom:zoom,animate:!reduceMotion).transition(.opacity)
        } else if loading { ProgressView("正在加载原图") }
        else { ContentUnavailableView("图片未能加载",systemImage:"photo",description:Text(error ?? "请重试")) }
      }.clipShape(.rect(cornerRadius:18)).frame(maxWidth:.infinity,maxHeight:.infinity)
      HStack(spacing:14) {
        Button { zoom = max(0.5,zoom/1.5) } label: { Image(systemName:"minus.magnifyingglass") }.help("缩小")
        Slider(value:$zoom,in:0.5...6).frame(width:160).accessibilityLabel("图片缩放")
        Button { zoom = min(6,zoom*1.5) } label: { Image(systemName:"plus.magnifyingglass") }.help("放大")
        Button("适应窗口") { zoom = 1 }
        Spacer()
        if original != nil { Text(ByteCountFormatter.string(fromByteCount:Int64(original?.count ?? 0),countStyle:.file)).font(.caption).foregroundStyle(.secondary) }
        if image == nil && !loading { Button("重试") { Task { await load() } } }
        Button(saved ? "已保存" : "保存原图…") { save() }.disabled(original == nil)
      }.buttonStyle(.appGlassButton)
      if let error, image != nil { Text(error).font(.caption).foregroundStyle(.secondary) }
    }.padding(20).frame(minWidth:700,minHeight:520).frame(width:900,height:680)
      .background { GlassBackdrop() }
      .onAppear { index = min(max(0,target.selected),max(0,target.urls.count-1)) }
      .task(id:address) { await load() }
  }
  private func change(_ delta:Int) {
    let next = index+delta; guard target.urls.indices.contains(next) else { return }
    withAnimation(reduceMotion ? nil : .easeInOut(duration:0.18)) { index = next; image = nil; zoom = 1; saved = false }
  }
  private func load() async {
    let source = address; loading = true; original = nil; error = nil; saved = false
    do {
      let normalized = source.hasPrefix("//") ? "https:"+source : source.replacingOccurrences(of:"http://",with:"https://")
      guard let url = URL(string:normalized) else { throw BiliError(text:"图片地址无效") }
      let data = try await ThumbnailCache.shared.data(url)
      let decoded = await Task.detached(priority:.userInitiated) { NSImage(data:data) }.value
      guard !Task.isCancelled, address == source else { return }
      guard let decoded, decoded.isValid else { throw BiliError(text:"图片无法解码") }
      original = data
      withAnimation(reduceMotion ? nil : .easeOut(duration:0.18)) { image = decoded }
    } catch { guard !Task.isCancelled, address == source else { return }; self.error = error.localizedDescription }
    loading = false
  }
  private func save() {
    guard let data = original else { return }
    let savedAddress = address
    let panel = NSSavePanel()
    let source = CGImageSourceCreateWithData(data as CFData,nil)
    let type = source.flatMap { CGImageSourceGetType($0) }.flatMap { UTType($0 as String) }
    panel.allowedContentTypes = [type ?? .image]
    panel.nameFieldStringValue = "bilibili-图片-\(index+1).\(type?.preferredFilenameExtension ?? "png")"
    panel.canCreateDirectories = true
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task {
        do {
          try await Task.detached { try data.write(to:url,options:.atomic) }.value
          if address == savedAddress { saved = true }
        } catch { if address == savedAddress { self.error = error.localizedDescription } }
      }
    }
  }
}
struct NativeImageCanvas: NSViewRepresentable {
  let image: NSImage
  let zoom: Double
  let animate: Bool
  final class CenteredClip: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
      var result = super.constrainBoundsRect(proposed)
      if let frame = documentView?.frame {
        if frame.width < result.width { result.origin.x = (frame.width-result.width)/2 }
        if frame.height < result.height { result.origin.y = (frame.height-result.height)/2 }
      }
      return result
    }
  }
  final class Scroll: NSScrollView {
    let picture = NSImageView()
    var requestedZoom = 1.0
    var needsFit = true
    private var lastViewport = NSSize.zero
    override init(frame:NSRect) {
      super.init(frame:frame)
      contentView = CenteredClip(); contentView.drawsBackground = false
      drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = true
      autohidesScrollers = true; allowsMagnification = true; minMagnification = 0.01; maxMagnification = 16
      picture.imageScaling = .scaleNone; picture.animates = true; documentView = picture
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
      super.layout()
      let viewport = contentSize
      if bounds.width > 0 && (needsFit || lastViewport != viewport) {
        needsFit = false; lastViewport = viewport
        applyZoom(animated:false)
      }
    }
    func applyZoom(animated:Bool) {
      guard let image = picture.image, image.size.width > 0, image.size.height > 0 else { return }
      picture.frame = NSRect(origin:.zero,size:image.size)
      let fit = min(contentSize.width/image.size.width,contentSize.height/image.size.height)
      let factor = min(16,max(0.01,fit*requestedZoom))
      if animated {
        NSAnimationContext.runAnimationGroup { context in context.duration = 0.18; context.timingFunction = CAMediaTimingFunction(name:.easeInEaseOut); animator().magnification = factor }
      } else {
        setMagnification(factor, centeredAt: CGPoint(x:image.size.width/2,y:image.size.height/2))
      }
    }
  }
  func makeNSView(context:Context) -> Scroll { Scroll() }
  func updateNSView(_ view:Scroll,context:Context) {
    if view.picture.image !== image { view.picture.image = image; view.needsFit = true; view.needsLayout = true }
    if view.requestedZoom != zoom { view.requestedZoom = zoom; view.applyZoom(animated:animate) }
  }
}
