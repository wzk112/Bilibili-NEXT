import SwiftUI

enum MacSidebarCollapseMode: String { case icons, hidden }

private struct MacSidebarGeometry {
  static let rowHeight: CGFloat = 40
  static let rowSpacing: CGFloat = 4
  static let compactInset: CGFloat = 6
  static let compactFooterHeight: CGFloat = 92
  static let footerSpacing: CGFloat = 14
  let reveal: CGFloat
  let width: CGFloat

  init(width: CGFloat) {
    self.width = max(AppLayout.compactSidebarWidth, width)
    reveal = min(1, max(0, (width - AppLayout.compactSidebarWidth) / (AppLayout.sidebarWidth - AppLayout.compactSidebarWidth)))
  }
  func blend(_ compact: CGFloat, _ expanded: CGFloat) -> CGFloat { compact + (expanded - compact) * reveal }
  var inset: CGFloat { blend(Self.compactInset, 8) }
  var iconInset: CGFloat { blend(9, 10) }
  var panelRadius: CGFloat { blend(AppLayout.compactSidebarWidth / 2, AppLayout.panelRadius) }
  var rowRadius: CGFloat { panelRadius - inset }
  var labelOpacity: Double { Double(min(1, max(0, (reveal - 0.20) / 0.55))) }
  var footerInset: CGFloat { blend(8, 12) }
  var footerHeight: CGFloat { blend(Self.compactFooterHeight, 60) }
}

struct MacSidebar: View {
  @Bindable var store: Store
  let preferences: BrowsePreferences
  let availableHeight: CGFloat

  var body: some View {
    GeometryReader { container in
      let shape = MacSidebarGeometry(width: container.size.width)
      let count = preferences.sidebarPages.count
      let rowsHeight = CGFloat(count) * MacSidebarGeometry.rowHeight
        + CGFloat(max(0, count - 1)) * MacSidebarGeometry.rowSpacing
      // The compact footer takes more extra space than the expanded row insets.
      // Decide from window height alone so a width animation cannot reinsert a scroller.
      let needsScroll = rowsHeight + MacSidebarGeometry.compactInset * 2 + MacSidebarGeometry.compactFooterHeight
        + MacSidebarGeometry.footerSpacing > availableHeight
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        if needsScroll {
          ScrollView(.vertical) { rows(shape: shape) }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(rowsHeight + shape.inset * 2,
              max(0, availableHeight - shape.footerHeight - MacSidebarGeometry.footerSpacing)))
            .clipShape(.rect(cornerRadius: shape.panelRadius))
            .floatingGlass(shape.panelRadius)
        } else {
          rows(shape: shape).floatingGlass(shape.panelRadius)
        }
        Spacer(minLength: 0)
        MacAccountFooter(store: store, shape: shape).padding(.top, MacSidebarGeometry.footerSpacing)
      }.frame(width: shape.width, height: container.size.height)
    }
  }

  private func rows(shape: MacSidebarGeometry) -> some View {
    VStack(spacing: MacSidebarGeometry.rowSpacing) {
      ForEach(preferences.sidebarPages) { page in
        if let destination = Destination(rawValue: page.title) {
          navigationRow(destination, page: page, shape: shape)
        }
      }
    }.padding(shape.inset).frame(maxWidth: .infinity)
  }

  private func navigationRow(_ destination: Destination, page: StartPage, shape: MacSidebarGeometry) -> some View {
    let selected = store.destination == destination && !store.showPlayer
    let row = RoundedRectangle(cornerRadius: shape.rowRadius)
    return Button { store.navigate(destination) } label: {
      Image(systemName: destination.icon)
        .frame(width: 22)
        .overlay(alignment: .leading) {
          Text(destination.rawValue).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .opacity(shape.labelOpacity).offset(x: 34)
        }
        .padding(.leading, shape.iconInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: MacSidebarGeometry.rowHeight)
        .clipped()
        .font(.system(size: 14, weight: selected ? .semibold : .regular))
        .background(selected ? biliPink.opacity(0.19) : .clear, in: row)
        .contentShape(row)
    }
    .buttonStyle(NavigationButtonStyle()).help(destination.rawValue)
    .accessibilityLabel(destination.rawValue).accessibilityIdentifier("sidebar-" + page.rawValue)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct MacAccountFooter: View {
  @Bindable var store: Store
  let shape: MacSidebarGeometry
  var body: some View {
    let controlWidth = CGFloat(AppMetrics.controlHeight)
    let identityWidth = max(32, shape.width - shape.footerInset * 2 - controlWidth - 8)
    ZStack(alignment: .topLeading) {
      identity.frame(width: identityWidth, height: 32, alignment: .leading).clipped()
        .offset(x: shape.blend((shape.width - 32) / 2, shape.footerInset), y: shape.blend(7, 14))
      settings.offset(x: shape.blend((shape.width - controlWidth) / 2, shape.width - shape.footerInset - controlWidth),
        y: shape.blend(47, (60 - controlWidth) / 2))
    }
    .frame(width: shape.width, height: shape.footerHeight, alignment: .topLeading)
    .floatingGlass(shape.panelRadius)
  }
  private var identity: some View {
    Button { store.navigate(.profile) } label: {
      Group {
        if let account = store.account {
          Thumbnail(url: account.face, mode: .fill, placeholder: "person.crop.circle.fill")
            .frame(width: 32, height: 32).clipShape(.circle)
        } else {
          Image(systemName: "person.crop.circle").font(.title2).frame(width: 32, height: 32)
        }
      }
      .overlay(alignment: .topTrailing) {
        if store.messageUnread.counts.total > 0 {
          Circle().fill(biliPink).frame(width: 7, height: 7).allowsHitTesting(false)
        }
      }
      .overlay(alignment: .leading) {
        Text(store.account?.name ?? "个人中心").lineLimit(1)
          .frame(width: max(0, shape.width - shape.footerInset * 2 - AppMetrics.controlHeight - 50), alignment: .leading)
          .opacity(shape.labelOpacity).offset(x: 42)
      }
      .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    }
    .buttonStyle(.pointerPlain).help("个人中心：消息、观看记录、收藏、稍后再看与下载")
    .accessibilityLabel("个人中心").accessibilityIdentifier("personal-center")
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
