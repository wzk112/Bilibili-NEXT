import SwiftUI

/// Shared avatar sizing and a meaningful fallback for accounts without a photo.
struct MobileAvatar: View {
  let url: String
  var system = false
  var body: some View {
    Thumbnail(url: url, placeholder: system ? "bell.fill" : "person.fill")
      .clipShape(.circle)
      .accessibilityHidden(true)
  }
}

struct MobileInbox: View {
  @Bindable var store: Store
  @State private var query = ""
  @State private var unreadOnly = false
  @State private var destination: Int?
  @State private var selectedConversation: Conversation?
  @State private var searching = false
  @Environment(\.dynamicTypeSize) private var textSize
  private var conversations: [Conversation] {
    store.inbox.conversations.filter {
      (!unreadOnly || $0.unread > 0)
        && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
          || $0.preview.localizedCaseInsensitiveContains(query))
    }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if searching {
          HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索名称或消息", text: $query).autocorrectionDisabled()
            Button("取消") {
              query = ""
              searching = false
            }
          }.padding(12).background(MobileSurface.inset, in: .rect(cornerRadius: 6))
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        AppGlassContainer(spacing: 12) {
          // These four persistent controls need their full geometry before the
          // glass container is composited. Only the conversation rows are lazy.
          Grid(horizontalSpacing: 12, verticalSpacing: 16) {
            GridRow {
              shortcut("回复我的", icon: "bubble.left.and.bubble.right.fill", color: .teal, kind: 1)
              shortcut("@我的", icon: "at", color: .blue, kind: 2)
              if !textSize.isAccessibilitySize {
                shortcut("收到的赞", icon: "hand.thumbsup.fill", color: biliPink, kind: 3)
                systemShortcut
              }
            }
            if textSize.isAccessibilitySize {
              GridRow {
                shortcut("收到的赞", icon: "hand.thumbsup.fill", color: biliPink, kind: 3)
                systemShortcut
              }
            }
          }.buttonStyle(.plain).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 22)
        }
        HStack(spacing: 12) {
          Text("私信").font(.subheadline.weight(.semibold))
          MessageUnreadBadge(count: store.messageUnread.counts.privateMessages)
          filter("全部", unread: false)
          filter("未读", unread: true)
          Spacer(minLength: 0)
        }.padding(.horizontal, 16).padding(.bottom, 8)
        if let error = store.messageUnread.error {
          HStack { Text(error).font(.caption).foregroundStyle(.secondary); Button("重试") { Task { await store.messageUnread.refresh(api: store.api) } } }.padding(.horizontal, 16)
        }
        if store.account == nil {
          ContentUnavailableView {
            Label("登录后查看消息", systemImage: "bubble.left.and.bubble.right")
          } actions: {
            Button("登录") { store.login() }.buttonStyle(.appGlassProminent)
          }
        } else {
          LazyVStack(spacing: 0) {
            ForEach(conversations) { conversation in
              Button {
                store.conversationPresented = true
                selectedConversation = conversation
              } label: {
                MobileConversationRow(conversation: conversation)
              }.buttonStyle(.plain).accessibilityIdentifier("conversation-\(conversation.id)")
                .padding(.horizontal, 16)
              Divider().padding(.leading, 80).padding(.trailing, 16)
            }
          }
          if store.inbox.loading { ProgressView("正在加载会话").frame(maxWidth: .infinity) }
          if let error = store.inbox.error {
            MobileError(text: error) { Task { await store.inbox.load(api: store.api); await store.messageUnread.refresh(api: store.api) } }
          }
          if conversations.isEmpty && !store.inbox.loading && store.inbox.error == nil {
            ContentUnavailableView(
              !query.isEmpty ? "没有匹配的会话" : unreadOnly ? "没有未读消息" : "暂无私信",
              systemImage: unreadOnly ? "checkmark.bubble" : "bubble.left.and.bubble.right",
              description: Text(!query.isEmpty ? "试试其他名称或消息关键词。" : "新消息会显示在这里。"))
          }
          if store.inbox.hasMore && !store.inbox.loading {
            Button("加载更多会话") { Task { await store.inbox.load(api: store.api, more: true) } }
              .frame(maxWidth: .infinity, minHeight: 44)
          }
        }
      }.frame(maxWidth: 840).frame(maxWidth: .infinity)
    }.background(MobileSurface.background)
      .navigationTitle("消息").navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(MobileSurface.background, for: .navigationBar)
      .toolbarBackgroundVisibility(.visible, for: .navigationBar)
      .toolbar {
        Button {
          searching.toggle()
          if !searching { query = "" }
        } label: {
          Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel("搜索消息")
      }
      .sheet(item: $selectedConversation, onDismiss: { store.conversationPresented = false }) {
        conversation in
        MobileConversationSheet(store: store, conversation: conversation)
      }
      .navigationDestination(item: $destination) { kind in
        if kind == 4 {
          MobileSystemInbox(store: store)
        } else {
          MobileNotifications(store: store, kind: kind)
            .navigationTitle(kind == 1 ? "回复我的" : kind == 2 ? "@我的" : "收到的赞")
            .navigationBarTitleDisplayMode(.inline)
        }
      }
      .refreshable { if store.account != nil { await store.inbox.load(api: store.api); await store.messageUnread.refresh(api: store.api) } }
      .task(id: store.account?.mid) {
        if store.account != nil { await store.inbox.load(api: store.api); await store.messageUnread.refresh(api: store.api) }
      }
  }
  private var systemShortcut: some View {
    Button { destination = 4 } label: {
      MobileInboxShortcut(title: "系统通知", icon: "bell.badge.fill", color: .orange)
    }.accessibilityIdentifier("inbox-system")
  }
  private func shortcut(_ title: String, icon: String, color: Color, kind: Int) -> some View {
    Button {
      destination = kind
    } label: {
      MobileInboxShortcut(title: title, icon: icon, color: color, unread: store.messageUnread.counts[kind])
    }.accessibilityValue(store.messageUnread.counts[kind] > 0 ? "\(store.messageUnread.counts[kind]) 条未读" : "无未读")
      .accessibilityIdentifier("inbox-category-\(kind)")
  }
  private func filter(_ title: String, unread: Bool) -> some View {
    Button {
      unreadOnly = unread
    } label: {
      Text(title).font(.subheadline.weight(unreadOnly == unread ? .semibold : .regular))
        .foregroundStyle(unreadOnly == unread ? biliPink : .secondary)
        .padding(.horizontal, 12).frame(minHeight: 36)
        .background(
          unreadOnly == unread ? biliPink.opacity(0.1) : .clear,
          in: .rect(cornerRadius: 12))
    }.buttonStyle(.plain).accessibilityAddTraits(unreadOnly == unread ? .isSelected : [])
      .accessibilityIdentifier(unread ? "inbox-filter-unread" : "inbox-filter-all")
  }
}

private struct MobileInboxShortcut: View {
  let title: String
  let icon: String
  let color: Color
  var unread = 0
  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: icon).font(.system(size: 25, weight: .semibold))
        .frame(width: 54, height: 54).foregroundStyle(color)
        .appGlassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay(alignment: .topTrailing) { MessageUnreadBadge(count: unread).offset(x: 12, y: -12) }
      Text(title).font(.caption.weight(.medium)).foregroundStyle(.primary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }.frame(maxWidth: .infinity).padding(.vertical, 4).contentShape(Rectangle())
  }
}

private struct MobileConversationRow: View {
  let conversation: Conversation
  @Environment(\.dynamicTypeSize) private var textSize
  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      MobileAvatar(url: conversation.face, system: conversation.system).frame(width: 50, height: 50)
      VStack(alignment: .leading, spacing: 7) {
        name
        if textSize.isAccessibilitySize { timestamp }
        Text(conversation.preview.isEmpty ? "暂无消息内容" : conversation.preview)
          .font(.subheadline).foregroundStyle(.secondary)
          .lineLimit(textSize.isAccessibilitySize ? 3 : 1)
          .frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .trailing, spacing: 12) {
        if !textSize.isAccessibilitySize { timestamp }
        if conversation.unread > 0 {
          Text(conversation.unread > 99 ? "99+" : String(conversation.unread))
            .font(.caption2.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(biliPink, in: .capsule).foregroundStyle(.white)
            .accessibilityLabel("\(conversation.unread) 条未读消息")
        }
      }.padding(.top, 3)
    }.padding(.vertical, 13).frame(minHeight: 76).contentShape(Rectangle())
      .accessibilityElement(children: .combine)
  }
  private var name: some View {
    Text(conversation.name).font(.body.weight(.medium)).foregroundStyle(.primary)
      .lineLimit(textSize.isAccessibilitySize ? 2 : 1)
  }
  @ViewBuilder private var timestamp: some View {
    if let date = conversation.date {
      Text(Self.timeLabel(date))
        .font(.caption2).foregroundStyle(.secondary).fixedSize()
    }
  }
  private static func timeLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour().minute()) }
    if calendar.isDateInYesterday(date) { return "昨天" }
    return date.formatted(
      .dateTime.month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN")))
  }

}

private struct MobileSystemInbox: View {
  @Bindable var store: Store
  // System pagination must not replace the user's private-message list or selection.
  @State private var model = InboxModel()
  var body: some View {
    List {
      if store.account == nil {
        ContentUnavailableView {
          Label("登录后查看通知", systemImage: "bell")
        } actions: {
          Button("登录") { store.login() }
        }
      } else {
        ForEach(model.conversations) { conversation in
          NavigationLink {
            MobileConversation(store: store, conversation: conversation, model: model)
          } label: {
            MobileConversationRow(conversation: conversation)
          }
        }
        if model.loading { ProgressView("正在加载系统通知") }
        if let error = model.error {
          MobileError(text: error) { Task { await model.load(api: store.api, systemOnly: true) } }
        }
        if model.conversations.isEmpty && !model.loading && model.error == nil {
          ContentUnavailableView("暂无系统通知", systemImage: "bell")
        }
        if model.hasMore && !model.loading {
          Button("加载更多通知") {
            Task { await model.load(api: store.api, more: true, systemOnly: true) }
          }
        }
      }
    }.listStyle(.plain).navigationTitle("系统通知").navigationBarTitleDisplayMode(.inline)
      .task(id: store.account?.mid) {
        if store.account != nil {
          await model.load(api: store.api, systemOnly: true)
        } else {
          model.clear()
        }
      }
      .refreshable {
        if store.account != nil { await model.load(api: store.api, systemOnly: true) }
      }
  }
}
