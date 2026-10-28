import Foundation
import Testing
@testable import BiliGlass

struct PlaybackSequenceTests {
  private let video = Video(bvid: "A", title: "A", cover: "", author: "", duration: 60, views: 0)
  private var detail: Detail {
    Detail(video: video, description: "", pages: [Page(id: 1, title: "第一部分", number: 1), Page(id: 2, title: "第二部分", number: 2)],
      collection: VideoCollection(title: "合集", items: [.init(bvid: "A", cid: 1, title: "A"), .init(bvid: "B", cid: 3, title: "B")]))
  }
  @Test func partsRemainDistinctFromCollection() {
    #expect(PlaybackSequence.parts(detail).map(\.title) == ["P1 · 第一部分", "P2 · 第二部分"])
    #expect(PlaybackSequence.next(detail: detail, cid: 1, queue: [], parts: true, collection: false)?.cid == 2)
    #expect(PlaybackSequence.next(detail: detail, cid: 1, queue: [], parts: false, collection: true) == nil)
    #expect(PlaybackSequence.next(detail: detail, cid: 2, queue: [], parts: true, collection: false) == nil)
    #expect(PlaybackSequence.next(detail: detail, cid: 2, queue: [], parts: true, collection: true)?.bvid == "B")
  }
  @Test func explicitQueueAndRepeatedBVDoNotLoopToCompletedPart() {
    let queue: [PlaybackQueueItem] = [.init(bvid: "A", cid: 1, title: "A1"), .init(bvid: "A", cid: 2, title: "A2"), .init(bvid: "C", title: "C")]
    #expect(PlaybackSequence.next(detail: detail, cid: 2, queue: queue, parts: true, collection: true)?.bvid == "C")
    #expect(PlaybackSequence.next(detail: detail, cid: 2, queue: Array(queue.prefix(2)), parts: true, collection: true) == nil)
    #expect(PlaybackSequence.next(detail: detail, cid: 999, queue: queue, parts: true, collection: true) == nil)
    #expect(PlaybackSequence.next(detail: nil, cid: 1, queue: queue, parts: true, collection: true) == nil)
  }
  @Test func singleVideoUsesCollectionOnlyWhenEnabled() {
    let single = Detail(video: video, description: "", pages: [], collection: detail.collection)
    #expect(PlaybackSequence.next(detail: single, cid: 1, queue: [], parts: true, collection: false) == nil)
    #expect(PlaybackSequence.next(detail: single, cid: 1, queue: [], parts: false, collection: true)?.bvid == "B")
  }
}

@MainActor struct BrowseReturnTests {
  @Test func independentQABundlesDoNotAccessReleaseCredentials() {
    #expect(Vault.sessionService(bundleIdentifier: "local.BiliGlass") == "local.BiliGlass.session")
    #expect(Vault.sessionService(bundleIdentifier: "com.wzk112.BilibiliNEXT.iOS") == "local.BiliGlass.session")
    #expect(Vault.sessionService(bundleIdentifier: nil) == "local.BiliGlass.session")
    #expect(Vault.sessionService(bundleIdentifier: "local.BiliGlass.FeedbackQA") == "local.BiliGlass.FeedbackQA.session")
    #expect(Vault.sessionService(bundleIdentifier: "com.wzk112.BilibiliNEXT.FeedbackQA") == "com.wzk112.BilibiliNEXT.FeedbackQA.session")
  }
  @Test func phoneNavigationIsPreservedWhenDuoExpandsOrRotates() {
    #expect(!AdaptiveNavigationLayout.usesColumns(width: 466, height: 678, isTablet: false))
    #expect(!AdaptiveNavigationLayout.usesColumns(width: 844, height: 390, isTablet: false))
    #expect(!AdaptiveNavigationLayout.usesColumns(width: 669, height: 951, isTablet: false))
    #expect(!AdaptiveNavigationLayout.usesColumns(width: 951, height: 669, isTablet: false))
    #expect(AdaptiveNavigationLayout.usesColumns(width: 500, height: 700, isTablet: true))
  }
  @Test func defaultsAndHiddenStartupFallback() throws {
    let name = "browse-preferences-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(BrowsePreferences(defaults: defaults).resolvedStart == .recommend)
    defaults.set(false, forKey: "showRecommended")
    #expect(BrowsePreferences(defaults: defaults).resolvedStart == .history)
    defaults.set("popular", forKey: "startPage")
    #expect(BrowsePreferences(defaults: defaults).resolvedStart == .popular)
    defaults.set(false, forKey: "showPopular")
    #expect(BrowsePreferences(defaults: defaults).resolvedStart == .history)
  }
  @Test func customizedNavigationKeepsOrderAndSafeFallbacks() throws {
    let name = "navigation-customization-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set("downloads,messages,downloads,unknown,history", forKey: "navigationItemOrder")
    defaults.set("recommend,popular,regions,dynamic,favorites,later,profile", forKey: "hiddenNavigationItems")
    let preferences = BrowsePreferences(defaults: defaults)
    #expect(preferences.visible.prefix(3) == [.downloads, .messages, .history])
    #expect(Set(preferences.order).count == preferences.order.count)
    #expect(preferences.phoneTabs == [3, 2, 4])
    #expect(preferences.resolvedStart == .history)
    defaults.set("recommend,popular,regions,dynamic,history,favorites,later,profile", forKey: "hiddenNavigationItems")
    #expect(BrowsePreferences(defaults: defaults).resolvedStart == .downloads)
    defaults.set(StartPage.allCases.map(\.rawValue).joined(separator: ","), forKey: "hiddenNavigationItems")
    #expect(BrowsePreferences(defaults: defaults).phoneTabs == [4])
    #expect(BrowsePreferences(defaults: defaults).resolvedStart == .profile)
    defaults.set("", forKey: "hiddenNavigationItems")
    defaults.set("NO", forKey: "showRecommended")
    #expect(!BrowsePreferences(defaults: defaults).allows(.recommend))
  }
  @Test func sidebarRoundTripKeepsFeedPaginationAndPosition() {
    let store = Store()
    store.destination = .popular
    store.videos = [Video(bvid: "saved", title: "saved", cover: "", author: "", duration: 60, views: 0)]
    store.page = 4; store.hasMore = false
    let position = store.browsePosition
    position.offset = 1234
    store.showPlayer = true
    store.navigate(.popular)
    #expect(!store.showPlayer)
    #expect(store.videos.first?.bvid == "saved")
    #expect(store.browsePosition === position)
    store.navigate(.web)
    store.selectedRegion = 1009
    store.navigate(.popular)
    #expect(store.videos.first?.bvid == "saved")
    #expect(store.page == 4 && !store.hasMore && !store.busy)
    #expect(store.browsePosition.offset == 1234)
  }
}
