import SwiftUI

struct EmojiPackage: Identifiable {
  let id: Int
  let title: String
  let emotes: [CommentEmote]
}
struct EmojiPicker: View {
  let api: API
  var insert: (CommentEmote) -> Void
  @State private var showing = false
  @State private var packages: [EmojiPackage] = []
  @State private var selected = 0
  @State private var error: String?
  var body: some View {
    Button {
      #if os(iOS)
      UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
      #endif
      showing.toggle()
    } label: {
      #if os(iOS)
      Image(systemName: "face.smiling").font(.system(size: 20, weight: .regular))
        .frame(width: 44, height: 44).appGlassEffect(.regular.interactive(), in: .circle)
      #else
      Image(systemName: "face.smiling")
      #endif
    }
    #if os(iOS)
    .buttonStyle(.plain)
    #else
    .buttonStyle(.appGlassButton)
    #endif
    .help("表情").accessibilityLabel("表情")
      .popover(isPresented: $showing) {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("表情").font(.headline)
            Spacer()
            Button { showing = false } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
              .buttonStyle(.plain).accessibilityLabel("关闭表情")
          }
          if !packages.isEmpty {
            Picker("表情包", selection: $selected) { ForEach(packages) { Text($0.title).tag($0.id) } }.pickerStyle(.menu).accessibilityIdentifier("emoji-package-picker")
            ScrollView {
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 10) {
                ForEach(packages.first(where: { $0.id == selected })?.emotes ?? [], id: \.token) { emote in
                  Button { insert(emote); showing = false } label: {
                    Thumbnail(url: emote.url.absoluteString, mode: .fit, placeholder: "face.smiling").frame(width: 36, height: 36).padding(4)
                  }.buttonStyle(.plain).help(emote.token).accessibilityLabel(emote.token)
                }
              }
            }.id(selected).accessibilityIdentifier("emoji-grid")
          } else if let error { Text(error).font(.callout).foregroundStyle(.secondary); Button("重试") { Task { await load() } } }
          else { ProgressView("正在加载表情") }
        }.padding(16)
        #if os(iOS)
        .frame(width: 300, height: 300)
        .presentationCompactAdaptation(.popover)
        #else
        .frame(width: 350, height: 320)
        #endif
        .task { if packages.isEmpty { await load() } }
      }
  }
  private func load() async {
    error = nil
    do {
      let data = try await api.request("/x/emote/user/panel/web", ["business": "reply"])
      try Task.checkCancellation()
      packages = (data["packages"] as? [[String: Any]] ?? []).compactMap { package in
        guard let id = package["id"] as? Int else { return nil }
        let emotes = (package["emote"] as? [[String: Any]] ?? []).compactMap { row -> CommentEmote? in
          guard let token = row["text"] as? String else { return nil }
          return CommentEmote.parse([token: row])[token]
        }
        return emotes.isEmpty ? nil : EmojiPackage(id: id, title: package["text"] as? String ?? "表情", emotes: emotes)
      }
      selected = packages.first?.id ?? 0
      if packages.isEmpty { error = "暂无可用表情" }
    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
  }
}
