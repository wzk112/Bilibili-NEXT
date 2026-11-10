import SwiftUI

enum MacSidebarCollapseMode: String { case icons, hidden }

struct MacSidebar: View {
  @Bindable var store: Store
  let preferences: BrowsePreferences
  let compact: Bool
  let availableHeight: CGFloat

  var body: some View {
    let footerHeight: CGFloat = compact ? 100 : 60
    let count = preferences.sidebarPages.count
    let navigationHeight = CGFloat(count) * 44 + CGFloat(max(0, count - 1)) * 4 + 16
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      ScrollView {
        VStack(spacing: 4) {
          ForEach(preferences.sidebarPages) { page in
            if let destination = Destination(rawValue: page.title) {
              Button { store.navigate(destination) } label: {
                HStack(spacing: 12) {
                  Image(systemName: destination.icon).frame(width: 22)
                  if !compact {
                    Text(destination.rawValue).lineLimit(1)
                    Spacer(minLength: 0)
                  }
                }
                .font(.system(size: 14, weight: store.destination == destination && !store.showPlayer ? .semibold : .regular))
                .frame(maxWidth: .infinity).frame(height: 44)
                .padding(.horizontal, compact ? 4 : 10)
                .background(store.destination == destination && !store.showPlayer ? biliPink.opacity(0.19) : .clear,
                  in: .rect(cornerRadius: AppLayout.panelRadius - (compact ? 4 : 8)))
                .contentShape(.rect(cornerRadius: AppLayout.panelRadius - (compact ? 4 : 8)))
              }
              .buttonStyle(NavigationButtonStyle()).help(destination.rawValue)
              .accessibilityLabel(destination.rawValue).accessibilityIdentifier("sidebar-" + page.rawValue)
            }
          }
        }.padding(compact ? 4 : 8).floatingGlass(AppLayout.panelRadius)
      }
      .frame(height: min(navigationHeight, max(0, availableHeight - footerHeight - 14)))
      .scrollIndicators(.hidden).compositingGroup().clipped()
      Spacer(minLength: 0)
      MacAccountFooter(store: store, compact: compact).padding(.top, 14)
    }.frame(maxHeight: .infinity).interfaceAnimation(compact)
  }
}

struct MacAccountFooter: View {
  @Bindable var store: Store
  let compact: Bool
  var body: some View {
    Group {
      if compact { VStack(spacing: 12) { identity; settings } }
      else { HStack(spacing: 10) { identity; settings } }
    }
    .padding(compact ? 8 : 12).frame(maxWidth: .infinity)
    .floatingGlass(AppLayout.panelRadius)
  }
  private var identity: some View {
    Button { store.navigate(.profile) } label: {
      HStack(spacing: 10) {
        if let account = store.account {
          Thumbnail(url: account.face, mode: .fill, placeholder: "person.crop.circle.fill")
            .frame(width: 32, height: 32).clipShape(.circle)
        } else {
          Image(systemName: "person.crop.circle").font(.title2).frame(width: 32, height: 32)
        }
        if !compact {
          Text(store.account?.name ?? "个人中心").lineLimit(1)
          Spacer(minLength: 0)
        }
      }.contentShape(.rect)
    }
    .buttonStyle(.pointerPlain).help("个人中心：消息、观看记录、收藏、稍后再看与下载")
    .accessibilityLabel("个人中心").accessibilityIdentifier("personal-center")
    .overlay(alignment: .topTrailing) {
      if store.messageUnread.counts.total > 0 {
        Circle().fill(biliPink).frame(width: 7, height: 7).allowsHitTesting(false)
      }
    }
  }
  private var settings: some View {
    SettingsLink { Image(systemName: "gearshape").frame(width: AppMetrics.controlHeight, height: AppMetrics.controlHeight).contentShape(.rect) }
      .buttonStyle(.pointerPlain).foregroundStyle(.secondary)
      .help("设置").accessibilityLabel("设置").accessibilityIdentifier("open-settings")
  }
}

struct MacNavigationMenu: View {
  @Bindable var store: Store
  let preferences: BrowsePreferences
  var body: some View {
    Menu {
      ForEach(preferences.sidebarPages) { page in
        if let destination = Destination(rawValue: page.title) {
          Button { store.navigate(destination) } label: { Label(page.title, systemImage: page.symbol) }
        }
      }
      Divider()
      Button { store.navigate(.profile) } label: { Label("个人中心", systemImage: "person.crop.circle") }
      SettingsLink { Label("设置", systemImage: "gearshape") }
    } label: { Image(systemName: "list.bullet") }
      .help("导航与个人中心").accessibilityLabel("导航与个人中心")
      .accessibilityIdentifier("compact-navigation")
  }
}

struct PersonalActionsRow: View {
  @Bindable var store: Store
  static let destinations: [Destination] = [.favorites, .later, .history, .downloads, .messages]
  var body: some View {
    HStack(spacing: 12) {
      ForEach(Self.destinations, id: \.self) { destination in
        Button { store.profileTarget = nil; store.navigate(destination) } label: {
          HStack(spacing: 8) {
            Image(systemName: destination.icon).foregroundStyle(biliPink)
            Text(destination.rawValue).lineLimit(1).minimumScaleFactor(0.85)
            if destination == .messages && store.messageUnread.counts.total > 0 {
              MessageUnreadBadge(count: store.messageUnread.counts.total)
            }
          }.font(.callout).frame(maxWidth: .infinity, minHeight: 26)
            .padding(.horizontal, 10).padding(.vertical, 13).floatingGlass(12)
            .contentShape(.rect(cornerRadius: 12))
        }.buttonStyle(.pointerPlain).help(destination.rawValue).accessibilityLabel(destination.rawValue)
          .accessibilityIdentifier("personal-" + destination.rawValue)
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
          Button(store.restoring ? "恢复登录中" : "登录") { store.login() }
            .buttonStyle(.appGlassButton).disabled(store.restoring)
        }.padding(24).floatingGlass(AppLayout.panelRadius)
        PersonalActionsRow(store: store)
      }.padding(AppLayout.pageInset).padding(.vertical, 8)
    }
  }
}
