import SwiftUI

/// Message cards have very different heights. Measure the loaded page as a whole so
/// the first wheel event cannot replace lazy height estimates and move the viewport.
struct ConversationTimeline<Content: View>: View {
  @Bindable var store: Store
  var model: InboxModel? = nil
  @ViewBuilder var bubble: (PrivateMessage) -> Content
  @State private var position = ScrollPosition(edge: .bottom)
  @State private var followingBottom = true
  @State private var interacting = false
  @State private var geometry = MessageTimelineGeometry()
  @State private var prepend: (first: String?, height: Double, offset: Double)?
  var body: some View {
    let inbox = model ?? store.inbox
    ScrollView {
      VStack(spacing: 16) {
        if inbox.hasOlder {
          Button("更早的消息") {
            prepend = (inbox.messages.first?.id, geometry.height, geometry.offset)
            Task { await inbox.loadMessages(api: store.api, older: true) }
          }.buttonStyle(.appGlassButton).disabled(inbox.loadingMessages)
        }
        ForEach(inbox.messages) { message in bubble(message).id(message.id) }
        Color.clear.frame(height: 1).id("bottom")
      }.padding(18).frame(maxWidth: .infinity).scrollTargetLayout()
    }
    .refreshable { await inbox.loadMessages(api: store.api) }
    .overlay { if inbox.loadingMessages && inbox.messages.isEmpty { ProgressView() } }
    .defaultScrollAnchor(.bottom, for: .initialOffset)
    .defaultScrollAnchor(.bottom, for: .alignment)
    .defaultScrollAnchor(followingBottom ? .bottom : .top, for: .sizeChanges)
    .scrollPosition($position)
    .onScrollPhaseChange { _, phase in
      interacting = phase == .tracking || phase == .interacting || phase == .decelerating
    }
    .onScrollGeometryChange(for: MessageTimelineGeometry.self) {
      MessageTimelineGeometry(offset: $0.contentOffset.y, height: $0.contentSize.height,
        viewport: $0.containerSize.height, bottomInset: $0.contentInsets.bottom)
    } action: { _, next in
      geometry = next
      if let saved = prepend, !inbox.loadingMessages, inbox.messages.first?.id != saved.first {
        prepend = nil
        position.scrollTo(y: max(0, saved.offset + next.height - saved.height))
      } else if interacting {
        followingBottom = next.isNearBottom
      }
    }
    .onChange(of: inbox.messages.last?.id) {
      if followingBottom && prepend == nil { position.scrollTo(edge: .bottom) }
    }
    .onChange(of: inbox.loadingMessages) { _, loading in
      if !loading, let saved = prepend, inbox.messages.first?.id == saved.first { prepend = nil }
    }
  }
}

struct MessageTimelineGeometry: Equatable {
  var offset = 0.0
  var height = 0.0
  var viewport = 0.0
  var bottomInset = 0.0
  var isNearBottom: Bool { offset + viewport >= height + bottomInset - 60 }
}
