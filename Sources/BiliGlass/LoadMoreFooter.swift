import SwiftUI

/// Visibility is measured against the scroll viewport, not LazyVStack prefetch.
/// A failed page stays still until Retry; state changes cannot create a retry loop.
struct LoadMoreFooter: View {
  let loading: Bool
  let hasMore: Bool
  let error: String?
  let count: Int
  var title = "加载更多"
  let load: () -> Void
  @AppStorage("autoLoadMore") private var automatic = true
  @State private var visible = false
  private var trigger: String { "\(visible)-\(automatic)-\(loading)-\(hasMore)-\(count)-\(error ?? "")" }
  var body: some View {
    VStack(spacing: 10) {
      if loading {
        ProgressView().controlSize(.small).accessibilityLabel("正在加载下一页")
      } else if let error {
        Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button("重试本页", action: load).buttonStyle(.appGlassButton)
      } else if hasMore {
        Button(title, action: load).buttonStyle(.appGlassButton)
        if automatic { Text("向下滚动自动加载").font(.caption).foregroundStyle(.secondary) }
      } else if count > 0 {
        Text("已加载全部内容").font(.caption).foregroundStyle(.secondary)
      }
    }.frame(maxWidth: .infinity).frame(minHeight: 54).padding(.vertical, 12)
      .onScrollVisibilityChange(threshold: 0.1) { visible = $0 }
      .task(id: trigger) {
        guard visible, automatic, !loading, hasMore, error == nil else { return }
        do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation() } catch { return }
        load()
      }
  }
}
