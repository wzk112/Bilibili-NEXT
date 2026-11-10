import SwiftUI

struct PersonalActionsRow: View {
  @Bindable var store: Store
  var body: some View {
    HStack(spacing: 12) {
      ForEach([Destination.favorites, .later, .history, .downloads, .messages], id: \.self) { destination in
        Button { store.profileTarget = nil; store.navigate(destination) } label: {
          HStack(spacing: 8) {
            Image(systemName: destination.icon).foregroundStyle(biliPink)
            Text(destination.rawValue).lineLimit(1).minimumScaleFactor(0.85)
            if destination == .messages && store.messageUnread.counts.total > 0 {
              MessageUnreadBadge(count: store.messageUnread.counts.total)
            }
          }.font(.callout).frame(maxWidth: .infinity, minHeight: 26)
            .padding(.horizontal, 10).padding(.vertical, 13).floatingGlass(AppLayout.itemRadius)
            .contentShape(.rect(cornerRadius: AppLayout.itemRadius))
        }.buttonStyle(.pointerPlain).help(destination.rawValue).accessibilityLabel(destination.rawValue)
      }
    }
  }
}

struct GuestAccountPage: View {
  @Bindable var store: Store
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 18) {
          Image(systemName: "person.crop.circle").font(.system(size: 56)).foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 8) {
            Text("个人中心").font(AppLayout.pageTitle)
            Text("登录后同步账号内容；本机观看记录和下载可直接查看。").foregroundStyle(.secondary)
          }
          Spacer()
          Button("登录") { store.login() }.buttonStyle(.pointerGlass).disabled(store.restoring)
        }.padding(24).floatingGlass(AppLayout.panelRadius)
        PersonalActionsRow(store: store)
      }.padding(AppLayout.pageInset).padding(.vertical, 8)
    }
  }
}
