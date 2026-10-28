import XCTest
import UIKit

@MainActor final class MobileSmokeTests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func openSessionAccount(_ app: XCUIApplication) {
    let tablet = app.buttons["tablet-nav-profile"]
    if tablet.waitForExistence(timeout: 3) { tablet.tap() }
    else {
      XCTAssertTrue(app.buttons["我的"].waitForExistence(timeout: 10))
      app.buttons["我的"].tap()
    }
  }

  func testSavedLoginSurvivesTerminationAndOfflineRelaunch() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-session-restoration", "--qa-session-seed"]
    app.launch()
    openSessionAccount(app)
    XCTAssertTrue(app.staticTexts["本地测试"].firstMatch.waitForExistence(timeout: 15))
    app.terminate()
    app.launchArguments = ["--qa-session-restoration", "--qa-session-offline"]
    app.launch()
    openSessionAccount(app)
    XCTAssertTrue(app.staticTexts["UID 1"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["登录哔哩哔哩"].firstMatch.exists)
    XCTAssertTrue(app.buttons["retry-account-restoration"].waitForExistence(timeout: 8))
    attach("saved-login-offline-relaunch", app: app)
    app.terminate()
    app.launchArguments = ["--qa-session-restoration"]
    app.launch()
    openSessionAccount(app)
    XCTAssertTrue(app.staticTexts["本地测试"].firstMatch.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["retry-account-restoration"].exists)
  }

  func testConfirmedExpiredLoginRequiresSignIn() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-session-restoration", "--qa-session-seed", "--qa-session-expired"]
    app.launch()
    openSessionAccount(app)
    XCTAssertTrue(app.staticTexts["登录已失效，请重新登录。"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["登录哔哩哔哩"].firstMatch.exists)
    XCTAssertFalse(app.buttons["retry-account-restoration"].exists)
  }

  private func interactionApp(_ extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-navigation", "--qa-app-coins"] + extra
    app.launch()
    XCTAssertTrue(app.buttons["video-coin"].waitForExistence(timeout: 15))
    return app
  }

  func testClientCoinFlowUpdatesLimitsWithoutVerificationButtons() {
    let app = interactionApp()
    app.buttons["video-coin"].tap()
    let submit = app.buttons["submit-coins"]
    XCTAssertTrue(submit.waitForExistence(timeout: 8))
    XCTAssertTrue(submit.isEnabled)
    XCTAssertFalse(app.buttons["官方验证"].exists)
    XCTAssertFalse(app.buttons["重新登录"].exists)
    submit.tap()
    XCTAssertTrue(app.staticTexts["已投 1 枚硬币"].waitForExistence(timeout: 8))
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.buttons["submit-coins"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["coin-amount-2"].isEnabled)
    XCTAssertTrue(app.staticTexts["已投 1 枚，本次最多投 1 枚"].waitForExistence(timeout: 5))
    attach("client-coin-confirmed", app: app)
    app.buttons["submit-coins"].tap()
    XCTAssertTrue(app.buttons["video-coin"].waitForExistence(timeout: 8))
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.staticTexts["本视频已投满"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["submit-coins"].isEnabled)
  }

  func testExpiredClientLoginOpensUnifiedQRAndCancelPreservesAccount() {
    let app = interactionApp(["--qa-token-expired"])
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.buttons["submit-coins"].waitForExistence(timeout: 8))
    app.buttons["submit-coins"].tap()
    XCTAssertTrue(app.staticTexts["请重新登录后再试"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["官方验证"].exists)
    for _ in 0..<4 {
      if app.buttons["interaction-relogin"].isHittable { break }
      app.collectionViews.firstMatch.swipeUp()
    }
    app.buttons["interaction-relogin"].tap()
    XCTAssertTrue(app.buttons["保存二维码到相册"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["使用哔哩哔哩 App 扫码，并确认登录"].waitForExistence(timeout: 8))
    attach("client-login-qr", app: app)
    app.buttons["关闭"].tap()
    XCTAssertTrue(app.buttons["video-coin"].waitForExistence(timeout: 8))
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.buttons["submit-coins"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.staticTexts["登录哔哩哔哩"].exists)
  }

  func testQRLoginRecoversNetworkLossAndBackgroundWithoutReplacingCode() {
    let app = interactionApp(["--qa-token-expired", "--qa-login-network-loss"])
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.buttons["submit-coins"].waitForExistence(timeout: 8))
    app.buttons["submit-coins"].tap()
    for _ in 0..<4 {
      if app.buttons["interaction-relogin"].isHittable { break }
      app.collectionViews.firstMatch.swipeUp()
    }
    app.buttons["interaction-relogin"].tap()
    XCTAssertTrue(app.staticTexts["连接暂时中断，正在恢复登录确认…"].waitForExistence(timeout: 8))
    let waiting = app.staticTexts["使用哔哩哔哩 App 扫码，并确认登录"]
    XCTAssertTrue(waiting.waitForExistence(timeout: 8))
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(waiting.waitForExistence(timeout: 8))
    XCTAssertTrue(app.buttons["保存二维码到相册"].isEnabled)
    XCTAssertFalse(app.buttons["刷新二维码"].exists)
    attach("qr-login-resumed", app: app)
    app.buttons["关闭"].tap()
  }

  func testTripleHoldCancelsOnReleaseAndCompletesWithoutExtraLike() {
    let app = interactionApp()
    let like = app.buttons["video-like"]
    XCTAssertTrue(like.waitForExistence(timeout: 8))
    like.tap()
    if !app.staticTexts["已点赞"].waitForExistence(timeout: 5) { print(app.debugDescription) }
    XCTAssertTrue(app.staticTexts["已点赞"].exists)
    XCTAssertEqual(like.value as? String, "1")
    like.tap()
    XCTAssertTrue(app.staticTexts["已取消点赞"].waitForExistence(timeout: 5))
    XCTAssertEqual(like.value as? String, "0")
    like.press(forDuration: 0.6)
    XCTAssertTrue(app.staticTexts["已取消点赞"].exists)
    XCTAssertFalse(app.staticTexts["triple-progress"].exists)
    XCTAssertEqual(like.value as? String, "0")
    like.press(forDuration: 1.5)
    XCTAssertTrue(app.staticTexts["已三连"].waitForExistence(timeout: 8))
    XCTAssertEqual(app.buttons["video-like"].value as? String, "1")
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.staticTexts["本视频已投满"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["submit-coins"].isEnabled)
    attach("triple-hold-confirmed", app: app)
  }

  func testCoinTimeoutRequiresRefreshBeforeAnotherSubmission() {
    let app = interactionApp(["--qa-coin-timeout"])
    app.buttons["video-coin"].tap()
    XCTAssertTrue(app.buttons["submit-coins"].waitForExistence(timeout: 8))
    app.buttons["submit-coins"].tap()
    XCTAssertTrue(app.staticTexts["投币结果未确认，请刷新状态后再操作"].waitForExistence(timeout: 8))
    XCTAssertFalse(app.buttons["submit-coins"].isEnabled)
    XCTAssertTrue(app.buttons["刷新状态"].isEnabled)
    XCTAssertTrue(app.buttons["重新登录"].exists)
    XCTAssertFalse(app.buttons["官方验证"].exists)
    attach("coin-uncertain-state", app: app)
  }

  func testNavigationSearchAndLocalHistory() throws {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["首页"].waitForExistence(timeout: 15))
    app.buttons["资料库"].tap()
    XCTAssertTrue(app.navigationBars["资料库"].exists)
    app.buttons["观看记录"].tap()
    XCTAssertTrue(app.navigationBars["观看记录"].waitForExistence(timeout: 5))
    attach("history", app: app)
    app.buttons["我的"].tap()
    for _ in 0..<6 {
      if app.buttons["设置"].isHittable { break }
      app.swipeUp()
    }
    app.buttons["设置"].tap()
    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    attach("settings", app: app)
    app.buttons["首页"].tap()
    app.buttons["搜索"].tap()
    attach("search-before-input", app: app)
    if !app.searchFields.firstMatch.waitForExistence(timeout: 5) { print(app.debugDescription) }
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
    app.searchFields.firstMatch.tap()
    app.searchFields.firstMatch.typeText("SwiftUI\n")
    attach("search", app: app)
  }

  func testLivePlaybackAndMiniPlayer() throws {
    guard ProcessInfo.processInfo.environment["BILI_IOS_LIVE_TEST"] == "1" else {
      throw XCTSkip("Set BILI_IOS_LIVE_TEST=1 to enable read-only live media validation")
    }
    let app = XCUIApplication()
    app.launchArguments = [
      "--qa-video", ProcessInfo.processInfo.environment["BILI_IOS_BVID"] ?? "BV1AHnB6NEhM",
    ]
    app.launch()
    XCTAssertTrue(app.navigationBars["正在播放"].waitForExistence(timeout: 20))
    app.buttons["播放详情"].tap()
    XCTAssertTrue(app.navigationBars["播放详情"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      waitForValue("rendered-frame-status", "是", app: app, timeout: 60),
      "AVKit must report a rendered video frame"
    )
    attach("live-playback-details", app: app)
    app.buttons["完成"].tap()
    checkMiniPlayer(app)
  }

  func testMiniPlayerAcrossTabs() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-video", "BV1AHnB6NEhM"]
    app.launch()
    XCTAssertTrue(app.navigationBars["正在播放"].waitForExistence(timeout: 20))
    checkMiniPlayer(app)
  }

  func testLongPressWithLocalFixture() throws {
    guard let fixture = ProcessInfo.processInfo.environment["BILI_IOS_FIXTURE"] else {
      throw XCTSkip(
        "Copy a local MP4 into app Documents/QA and set BILI_IOS_FIXTURE to its filename")
    }
    let app = XCUIApplication()
    app.launchArguments = ["--qa-fixture", fixture]
    app.launch()
    XCTAssertTrue(app.navigationBars["正在播放"].waitForExistence(timeout: 20))
    app.buttons["播放详情"].tap()
    XCTAssertTrue(waitForValue("rendered-frame-status", "是", app: app))
    app.buttons["完成"].tap()
    let video = app.otherElements["player-viewport"].firstMatch
    XCTAssertTrue(video.waitForExistence(timeout: 5))
    video.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35)).press(forDuration: 2)
    app.buttons["播放详情"].tap()
    XCTAssertTrue(waitForValue("temporary-speed-status", "未启用", app: app))
    attach("long-press-released", app: app)
  }
  func testSpecialDanmakuWithLocalFixture() throws {
    guard let fixture = ProcessInfo.processInfo.environment["BILI_IOS_FIXTURE"] else {
      throw XCTSkip("Requires local MP4 and special.json fixtures in app Documents/QA")
    }
    let app = XCUIApplication()
    app.launchArguments = ["--qa-fixture", fixture, "--qa-special"]
    app.launch()
    XCTAssertTrue(app.navigationBars["正在播放"].waitForExistence(timeout: 20))
    attach("advanced-danmaku", app: app)
    app.buttons["播放详情"].tap()
    let count = app.descendants(matching: .any)["special-layer-count"].firstMatch
    XCTAssertTrue(count.waitForExistence(timeout: 10))
    let rendered = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != '0'"), object: count)
    XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 20), .completed)
    attach("advanced-danmaku-details", app: app)
  }

  func testDoneSavesFavoriteSelectionWithManyFolders() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-favorite-form"]
    app.launch()
    let folder = app.switches["favorite-folder-1"]
    XCTAssertTrue(folder.waitForExistence(timeout: 15))
    XCTAssertEqual(folder.value as? String, "0")
    XCTAssertTrue(folder.label.contains("私密"))
    XCTAssertTrue(app.switches["favorite-folder-2"].label.contains("公开"))
    // The row and its native UISwitch are separate accessibility elements.
    folder.switches.firstMatch.tap()
    XCTAssertEqual(folder.value as? String, "1")
    app.buttons["save-favorites"].tap()
    let closed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.buttons["save-favorites"])
    XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "收藏，")).firstMatch.tap()
    XCTAssertTrue(folder.waitForExistence(timeout: 5))
    XCTAssertEqual(folder.value as? String, "1")
    attach("favorite-saved-and-reopened", app: app)
    app.buttons["取消"].tap()
  }
  func testMessageUnreadCountsAndLikeObjects() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-inbox"]
    app.launch()
    let likes = app.buttons["inbox-category-3"]
    XCTAssertTrue(likes.waitForExistence(timeout: 10))
    let unread = NSPredicate(format: "value == %@", "12 条未读")
    expectation(for: unread, evaluatedWith: likes)
    waitForExpectations(timeout: 8)
    XCTAssertEqual(app.buttons["inbox-category-1"].value as? String, "4 条未读")
    XCTAssertEqual(app.buttons["inbox-category-2"].value as? String, "2 条未读")
    attach("message-unread-counts", app: app)
    likes.tap()
    XCTAssertTrue(app.staticTexts["示例用户等 12 人赞了你的视频"].waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts["另一位用户赞了你的评论"].exists)
    XCTAssertTrue(app.staticTexts["我发布的视频标题"].exists)
    XCTAssertFalse(app.buttons["查看并回复"].exists)
    attach("message-like-objects", app: app)
    goBack(app)
    XCTAssertTrue(likes.waitForExistence(timeout: 8))
    XCTAssertEqual(likes.value as? String, "无未读")
    XCTAssertEqual(app.buttons["inbox-category-1"].value as? String, "4 条未读")
    app.buttons["inbox-category-1"].tap()
    XCTAssertTrue(app.buttons["查看并回复"].waitForExistence(timeout: 8))
    goBack(app)
    XCTAssertEqual(app.buttons["inbox-category-1"].value as? String, "无未读")
    XCTAssertEqual(app.buttons["inbox-category-2"].value as? String, "2 条未读")
  }

  func testInboxShortcutsAfterSearchAndRotation() {
    let app = XCUIApplication()
    defer { XCUIDevice.shared.orientation = .portrait }
    for largeText in [false, true] {
      app.launchArguments = ["--qa-ui", "--qa-inbox", "-appearance", "dark"]
      if largeText {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
      }
      for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
        XCUIDevice.shared.orientation = orientation
        app.launch()
        let first = app.buttons["inbox-category-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        app.buttons["搜索消息"].tap()
        XCTAssertTrue(app.textFields["搜索名称或消息"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        for id in ["inbox-category-1", "inbox-category-2", "inbox-category-3", "inbox-system"] {
          let button = app.buttons[id]
          // Accessibility text can put the second row below the short landscape
          // viewport on iPhone. It must remain reachable by ordinary scrolling.
          for _ in 0..<3 where !button.isHittable {
            let scroll = app.scrollViews.firstMatch
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.72))
              .press(forDuration: 0.05, thenDragTo: scroll.coordinate(
                withNormalizedOffset: CGVector(dx: 0.9, dy: 0.50)))
          }
          XCTAssertTrue(button.isHittable, id)
          XCTAssertGreaterThanOrEqual(button.frame.height, 75, id)
          if !largeText {
            XCTAssertGreaterThanOrEqual(button.frame.minY, app.navigationBars.firstMatch.frame.maxY, id)
          }
        }
        attach("inbox-shortcuts-\(largeText)-\(orientation.rawValue)", app: app)
        app.terminate()
      }
    }
  }

  func testInboxLayoutCategoriesAndUnreadFilter() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui"]
    app.launch()
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["conversation-1:11"].waitForExistence(timeout: 10))
    attach("inbox-light", app: app)
    app.buttons["inbox-filter-unread"].tap()
    XCTAssertFalse(app.buttons["conversation-1:12"].exists)
    XCTAssertTrue(app.buttons["conversation-1:11"].exists)
    app.buttons["inbox-filter-all"].tap()
    XCTAssertTrue(app.buttons["conversation-1:12"].exists)
    for kind in 1...3 {
      app.buttons["inbox-category-\(kind)"].tap()
      let expected = kind == 3 ? "示例用户等 12 人赞了你的视频" : "这里显示被回复的原文。"
      XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5))
      attach("inbox-category-\(kind)", app: app)
      goBack(app)
    }
    app.buttons["inbox-system"].tap()
    XCTAssertTrue(app.staticTexts["系统通知 1"].waitForExistence(timeout: 5))
    attach("system-notifications", app: app)
    goBack(app)
    XCTAssertTrue(app.buttons["conversation-1:12"].waitForExistence(timeout: 5))
    app.buttons["conversation-1:12"].tap()
    XCTAssertTrue(app.staticTexts["本地会话内容"].waitForExistence(timeout: 5))
    attach("conversation", app: app)
    app.buttons["查看消息图片"].tap()
    let zoom = app.scrollViews["image-zoom-view"]
    XCTAssertTrue(zoom.waitForExistence(timeout: 5))
    zoom.doubleTap()
    XCTAssertTrue(waitForValue("image-zoom-view", "已放大", app: app))
    zoom.swipeLeft()
    attach("gallery-zoom-and-pan", app: app)
    zoom.doubleTap()
    XCTAssertTrue(waitForValue("image-zoom-view", "适应屏幕", app: app))
    app.buttons["完成"].tap()
  }

  func testInboxFailureRetryAndEmptyStates() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-ui-error", "--qa-ui-empty"]
    app.launch()
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 10))
    attach("inbox-offline", app: app)
    app.buttons["重试"].tap()
    XCTAssertTrue(app.staticTexts["暂无私信"].waitForExistence(timeout: 5))
    app.buttons["inbox-filter-unread"].tap()
    XCTAssertTrue(app.staticTexts["没有未读消息"].exists)
    app.buttons["动态"].tap()
    XCTAssertTrue(app.staticTexts["暂无动态"].waitForExistence(timeout: 5))
    app.buttons["资料库"].tap()
    app.buttons["收藏"].tap()
    XCTAssertTrue(app.staticTexts["还没有收藏夹"].waitForExistence(timeout: 5))
    attach("favorite-empty", app: app)
  }

  func testInboxLargeTextAndSettingsNavigation() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--qa-ui", "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXXXL", "-appearance", "dark",
    ]
    app.launch()
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["inbox-category-1"].waitForExistence(timeout: 10))
    attach("inbox-dark-large-text", app: app)
    app.buttons["我的"].tap()
    for _ in 0..<6 {
      if app.buttons["设置"].isHittable { break }
      app.swipeUp()
    }
    app.buttons["设置"].tap()
    for _ in 0..<8 {
      if app.buttons["过滤与滚动设置"].isHittable { break }
      app.swipeUp()
    }
    app.buttons["过滤与滚动设置"].tap()
    XCTAssertTrue(app.navigationBars["弹幕设置"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.navigationBars.count, 1)
    attach("danmaku-settings-large-text", app: app)
    goBack(app)
    XCTAssertTrue(app.navigationBars["设置"].exists)
  }

  func testUserSearchClearsStaleResultsAfterFailure() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui"]
    app.launch()
    app.buttons["首页"].tap()
    app.buttons["搜索"].tap()
    app.buttons["搜索筛选"].tap()
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "搜索类型")).firstMatch.tap()
    app.buttons["用户"].tap()
    app.buttons["完成"].tap()
    let field = app.searchFields.firstMatch
    field.tap()
    field.typeText("甲\n")
    XCTAssertTrue(app.staticTexts["搜索用户 甲"].waitForExistence(timeout: 5))
    field.tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "失败\n")
    XCTAssertTrue(app.buttons["重试"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["搜索用户 甲"].exists)
    attach("search-error-without-stale-results", app: app)
  }

  func testPlayerReturnsThroughProfileAndPreservesComments() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-navigation"]
    app.launch()
    XCTAssertTrue(app.staticTexts["player-title"].waitForExistence(timeout: 10))
    let comments = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "评论 "))
      .firstMatch
    for _ in 0..<5 {
      if comments.isHittable { break }
      app.swipeUp()
    }
    comments.tap()
    let draft = app.descendants(matching: .any).matching(identifier: "comment-draft").firstMatch
    for _ in 0..<5 {
      if draft.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(draft.waitForExistence(timeout: 5))
    draft.tap()
    if app.buttons["Continue"].exists { app.buttons["Continue"].tap() }
    draft.typeText("保留的评论草稿")
    app.swipeDown()
    let author = app.buttons["player-author"].firstMatch
    for _ in 0..<5 {
      if author.isHittable { break }
      app.swipeDown()
    }
    author.tap()
    XCTAssertTrue(app.navigationBars["导航测试 UP 主"].waitForExistence(timeout: 5))
    attach("navigation-profile", app: app)
    let next = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "导航测试视频 B")).firstMatch
    for _ in 0..<5 {
      if next.isHittable { break }
      app.swipeUp()
    }
    next.tap()
    XCTAssertTrue(app.staticTexts["player-title"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["player-title"].label, "导航测试视频 B")
    attach("navigation-video-b", app: app)
    goBack(app)
    XCTAssertTrue(app.navigationBars["导航测试 UP 主"].waitForExistence(timeout: 5))
    goBack(app)
    for _ in 0..<5 {
      if draft.exists { break }
      app.swipeUp()
    }
    XCTAssertEqual(draft.value as? String, "保留的评论草稿")
    attach("navigation-restored-comments", app: app)
    app.buttons["播放详情"].tap()
    XCTAssertTrue(app.navigationBars["播放详情"].waitForExistence(timeout: 5))
    attach("navigation-restored-details", app: app)
    app.buttons["完成"].tap()
    app.buttons["收起播放器"].tap()
    XCTAssertTrue(app.buttons["关闭播放器"].waitForExistence(timeout: 5))
  }

  func testLibraryAndAccountPages() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-ui-pages", "-appearance", "light"]
    app.launch()
    attach("home", app: app)
    for name in ["热门", "分区", "推荐"] {
      app.buttons[name].tap()
      attach("home-" + name, app: app)
    }
    app.buttons["动态"].tap()
    attach("dynamics", app: app)
    app.buttons["发布动态"].tap()
    XCTAssertTrue(app.navigationBars["发布动态"].waitForExistence(timeout: 5))
    attach("dynamic-composer", app: app)
    app.buttons["取消"].tap()
    app.buttons["资料库"].tap()
    for name in ["收藏", "稍后再看", "观看记录", "下载"] {
      app.buttons[name].tap()
      XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 5))
      attach("library-" + name, app: app)
      goBack(app)
    }
    app.buttons["我的"].tap()
    attach("account", app: app)
    app.buttons["设置"].tap()
    attach("settings-top", app: app)
    for _ in 0..<7 {
      if app.buttons["开源许可"].isHittable { break }
      app.swipeUp()
    }
    attach("settings-bottom", app: app)
    app.buttons["开源许可"].tap()
    XCTAssertTrue(app.navigationBars["开源许可"].waitForExistence(timeout: 5))
    attach("licenses", app: app)
  }

  func testPlayerLargeTextAndInteractionSheets() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--qa-ui", "--qa-navigation", "-appearance", "dark",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    XCTAssertTrue(app.buttons["播放详情"].waitForExistence(timeout: 10))
    attach("player-large-top", app: app)
    let coin = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "投币，")).firstMatch
    for _ in 0..<8 {
      if coin.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(coin.isHittable)
    attach("player-large-actions", app: app)
    coin.tap()
    XCTAssertTrue(app.navigationBars["投币"].waitForExistence(timeout: 5))
    attach("coin-sheet-large", app: app)
    app.buttons["完成"].tap()
    let comments = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "评论 "))
      .firstMatch
    for _ in 0..<8 {
      if comments.isHittable { break }
      app.swipeUp()
    }
    comments.tap()
    app.swipeUp()
    attach("player-large-comment-editor", app: app)
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "comment-draft").firstMatch.exists)
  }

  func testCompactConversationComposerEmojiAndStableBottomBar() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "-appearance", "dark"]
    app.launch()
    XCTAssertTrue(app.buttons["消息"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.buttons.matching(identifier: "消息").count, 1)
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["conversation-1:12"].waitForExistence(timeout: 5))
    attach("inbox-liquid-glass-dark", app: app)
    let bottom = app.buttons["资料库"].frame.minY
    for _ in 0..<2 {
      app.buttons["conversation-1:12"].tap()
      XCTAssertTrue(app.buttons["关闭会话"].waitForExistence(timeout: 5))
      XCTAssertGreaterThan(app.navigationBars["测试会话 2"].frame.minY, app.frame.height * 0.15)
      attach("conversation-compact", app: app)
      let emoji = app.buttons["表情"].frame
      let photo = app.buttons["选择消息图片"].frame
      XCTAssertEqual(emoji.height, photo.height, accuracy: 1)
      XCTAssertEqual(emoji.width, photo.width, accuracy: 1)
      XCTAssertEqual(emoji.midY, photo.midY, accuracy: 1)
      app.buttons["表情"].tap()
      XCTAssertTrue(app.buttons["关闭表情"].waitForExistence(timeout: 5))
      attach("emoji-compact", app: app)
      app.buttons["关闭表情"].tap()
      app.buttons["关闭会话"].tap()
      XCTAssertTrue(app.buttons["conversation-1:12"].waitForExistence(timeout: 5))
      XCTAssertEqual(app.buttons.matching(identifier: "资料库").count, 1)
      XCTAssertEqual(app.buttons["资料库"].frame.minY, bottom, accuracy: 1)
    }
    app.buttons["动态"].tap()
    app.buttons["发布动态"].tap()
    XCTAssertTrue(app.navigationBars["发布动态"].waitForExistence(timeout: 5))
    XCTAssertGreaterThan(app.navigationBars["发布动态"].frame.minY, app.frame.height * 0.2)
    attach("composer-half-height", app: app)
    app.buttons["取消"].tap()
    XCTAssertEqual(app.buttons["资料库"].frame.minY, bottom, accuracy: 1)
  }

  func testEmojiPopoverDismissesKeyboardAndPreservesDraft() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "-appearance", "dark"]
    app.launch()
    XCTAssertTrue(app.buttons["消息"].waitForExistence(timeout: 10))
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["conversation-1:12"].waitForExistence(timeout: 5))
    app.buttons["conversation-1:12"].tap()
    let input = app.descendants(matching: .any)["message-input"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    input.typeText("Keep this draft")
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    app.buttons["表情"].tap()
    XCTAssertTrue(app.buttons["关闭表情"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    attach("emoji-after-keyboard", app: app)
    app.buttons["关闭表情"].tap()
    XCTAssertEqual(input.value as? String, "Keep this draft")
    app.buttons["关闭会话"].tap()
  }

  func testVideoFromCompactConversationReturnsToConversationAndStableDock() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-message-video"]
    app.launch()
    app.buttons["消息"].tap()
    XCTAssertTrue(app.buttons["conversation-1:12"].waitForExistence(timeout: 5))
    app.buttons["conversation-1:12"].tap()
    XCTAssertTrue(app.buttons["消息中的视频"].waitForExistence(timeout: 5))
    app.buttons["消息中的视频"].tap()
    XCTAssertTrue(app.staticTexts["player-title"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["player-title"].label, "导航测试视频 A")
    app.buttons["收起播放器"].tap()
    XCTAssertTrue(app.buttons["关闭会话"].waitForExistence(timeout: 5))
    attach("video-returned-to-conversation", app: app)
    app.buttons["关闭会话"].tap()
    XCTAssertTrue(app.buttons["mini-player-open"].waitForExistence(timeout: 5))
    let bottom = app.buttons["资料库"].frame.minY
    for _ in 0..<2 {
      app.buttons["mini-player-open"].tap()
      XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 5))
      app.buttons["收起播放器"].tap()
      XCTAssertTrue(app.buttons["mini-player-open"].waitForExistence(timeout: 5))
      XCTAssertEqual(app.buttons.matching(identifier: "资料库").count, 1)
      XCTAssertEqual(app.buttons["资料库"].frame.minY, bottom, accuracy: 1)
    }
    attach("stable-dock-with-mini-player", app: app)
    app.buttons["关闭播放器"].tap()
  }

  func testNoticeOpensExactCommentAndLocalReplySheet() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui"]
    app.launch()
    app.buttons["消息"].tap()
    app.buttons["inbox-category-1"].tap()
    XCTAssertTrue(app.buttons["查看并回复"].waitForExistence(timeout: 5))
    app.buttons["查看并回复"].tap()
    XCTAssertTrue(app.staticTexts["可以实现一层一层返回吗？"].waitForExistence(timeout: 10))
    app.buttons["回复"].firstMatch.tap()
    XCTAssertTrue(app.navigationBars["回复评论"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["回复 @导航测试 UP 主"].exists)
    attach("notice-exact-reply-sheet", app: app)
    let draft = app.textViews["comment-draft"].exists ? app.textViews["comment-draft"] : app.textFields["comment-draft"]
    draft.tap()
    draft.typeText("通知回复测试")
    app.buttons["发送"].tap()
    XCTAssertTrue(app.navigationBars["评论回复"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["回复成功"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["同一条评论下的回复"].exists)
    attach("notice-sent-reply-visible", app: app)
    XCTAssertTrue(app.buttons["本地测试"].exists || app.staticTexts["本地测试"].exists)
    app.buttons["查看原页面"].tap()
    XCTAssertTrue(app.navigationBars["原页面"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.state, .runningForeground)
    app.buttons["完成"].tap()
    XCTAssertTrue(app.navigationBars["评论回复"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["回复成功"].exists)
  }

  func testFullscreenControlsAndHoldWithLocalFixture() throws {
    let fixture = ProcessInfo.processInfo.environment["BILI_IOS_FIXTURE"] ?? "gesture.mp4"
    let app = XCUIApplication()
    app.launchArguments = ["--qa-fixture", fixture]
    app.launch()
    XCTAssertTrue(app.buttons["播放详情"].waitForExistence(timeout: 15))
    app.buttons["播放详情"].tap()
    XCTAssertTrue(waitForValue("rendered-frame-status", "是", app: app))
    app.buttons["完成"].tap()
    // Test the full touch target, including the space outside the small icon glyph.
    app.buttons["全屏"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15)).tap()
    XCTAssertTrue(app.buttons["退出全屏"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["清晰度"].exists)
    let pause = app.buttons["player-play-pause"]
    XCTAssertEqual(pause.value as? String, "正在播放")
    pause.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15)).tap()
    XCTAssertEqual(pause.value as? String, "已暂停")
    XCTAssertTrue(app.buttons["退出全屏"].exists)
    pause.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.85)).tap()
    XCTAssertEqual(pause.value as? String, "正在播放")
    let dm = app.buttons["关闭弹幕"].exists ? app.buttons["关闭弹幕"] : app.buttons["开启弹幕"]
    let old = dm.label
    dm.tap()
    XCTAssertTrue(app.buttons[old == "关闭弹幕" ? "开启弹幕" : "关闭弹幕"].exists)
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 2)
    attach("fullscreen-controls-after-hold", app: app)
    app.buttons["退出全屏"].coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15)).tap()
    XCTAssertTrue(app.buttons["播放详情"].waitForExistence(timeout: 5))
    app.buttons["播放详情"].tap()
    XCTAssertTrue(waitForValue("temporary-speed-status", "未启用", app: app))
  }

  func testEmojiPackageSwitchResetsScroll() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui"]
    app.launch()
    app.buttons["消息"].tap()
    app.buttons["conversation-1:12"].tap()
    app.buttons["表情"].tap()
    XCTAssertTrue(app.buttons["[组1-1]"].waitForExistence(timeout: 5))
    attach("emoji-before-scroll", app: app)
    let first = app.buttons["[组1-1]"]
    first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 2)).press(forDuration: 0.1, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -2)))
    app.buttons["emoji-package-picker"].tap()
    app.buttons["表情组 2"].tap()
    XCTAssertTrue(app.buttons["[组2-1]"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["[组2-1]"].isHittable)
    attach("emoji-new-package-top", app: app)
  }

  func testLandscapeAutomaticallyPresentsFullscreen() throws {
    guard UIDevice.current.userInterfaceIdiom == .phone else {
      throw XCTSkip("iPad uses explicit fullscreen and keeps the detail column visible on rotation.")
    }
    if ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4" {
      throw XCTSkip("The installed iPhone Duo runtime does not deliver physical rotation; verify automatic fullscreen on iPhone hardware.")
    }
    let app = XCUIApplication()
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    app.launchArguments = ["--qa-ui", "--qa-navigation"]
    app.launch()
    XCTAssertTrue(app.buttons["全屏"].waitForExistence(timeout: 10))
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.buttons["退出全屏"].waitForExistence(timeout: 10))
    attach("landscape-auto-fullscreen", app: app)
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.buttons["全屏"].waitForExistence(timeout: 10))
  }

  func testIPadPlayerRotationPreservesCommentsAndExplicitFullscreen() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout") }
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-navigation"]
    app.launch()
    maximizeIPadWindow()
    let title = app.staticTexts["player-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 15))
    let surface = app.otherElements["player-viewport"].firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["全屏"].isHittable)
    XCTAssertTrue(app.buttons["tablet-nav-recommend"].isHittable)
    XCTAssertFalse(app.buttons["退出全屏"].exists)
    XCTAssertGreaterThan(title.frame.minY, surface.frame.maxY)
    attach("ipad-desktop-player", app: app)
    let info = app.scrollViews["player-information"]
    let comments = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "评论 ")).firstMatch
    revealIPadElement(comments, scroll: info)
    comments.tap()
    let input = app.descendants(matching: .any).matching(identifier: "comment-draft").firstMatch
    revealIPadElement(input, scroll: info)
    input.tap()
    input.typeText("iPad retained draft")
    if app.buttons["Hide keyboard"].isHittable { app.buttons["Hide keyboard"].tap() }
    info.swipeDown()
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, "iPad retained draft")
    attach("ipad-portrait-comments", app: app)
    XCUIDevice.shared.orientation = .landscapeLeft
    revealIPadElement(input, scroll: info)
    XCTAssertEqual(input.value as? String, "iPad retained draft")
    for _ in 0..<8 {
      if surface.frame.minY >= app.navigationBars["正在播放"].frame.maxY { break }
      info.swipeDown()
    }
    app.buttons["全屏"].tap()
    XCTAssertTrue(app.buttons["退出全屏"].waitForExistence(timeout: 5))
    attach("ipad-explicit-fullscreen", app: app)
    app.buttons["退出全屏"].tap()
    XCTAssertTrue(app.buttons["全屏"].waitForExistence(timeout: 5))
    revealIPadElement(input, scroll: info)
    XCTAssertEqual(input.value as? String, "iPad retained draft")
    app.buttons["收起播放器"].tap()
    XCTAssertTrue(app.buttons["关闭播放器"].waitForExistence(timeout: 5))
    app.buttons["tablet-nav-history"].tap()
    XCTAssertTrue(app.buttons["关闭播放器"].exists)
    app.buttons["mini-player-open"].tap()
    XCTAssertTrue(title.waitForExistence(timeout: 5))
    revealIPadElement(input, scroll: info)
    XCTAssertEqual(input.value as? String, "iPad retained draft")
  }

  func testIPadBrowseGridAndNavigation() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout") }
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-ui-pages"]
    app.launch()
    maximizeIPadWindow()
    let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-card-"))
    XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 15))
    XCTAssertGreaterThanOrEqual(cards.count, 4)
    XCTAssertGreaterThanOrEqual(cards.element(boundBy: 0).frame.width, 240)
    XCTAssertEqual(cards.element(boundBy: 0).frame.minY, cards.element(boundBy: 2).frame.minY, accuracy: 2)
    XCTAssertLessThan(app.buttons["tablet-nav-recommend"].frame.maxX, cards.firstMatch.frame.minX)
    attach("ipad-desktop-browse", app: app)
    app.buttons["tablet-nav-messages"].tap()
    XCTAssertTrue(app.buttons["inbox-system"].waitForExistence(timeout: 5))
    attach("ipad-desktop-inbox", app: app)
    app.buttons["tablet-nav-history"].tap()
    XCTAssertTrue(app.navigationBars["观看记录"].waitForExistence(timeout: 5))
    app.buttons["设置"].tap()
    XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
    let search = app.textFields["tablet-search"]
    search.tap()
    search.typeText("iPad\n")
    XCTAssertTrue(app.navigationBars["iPad"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["搜索筛选"].exists)
    XCTAssertFalse(app.searchFields.firstMatch.exists)
    attach("ipad-desktop-search", app: app)
  }

  func testIPadAccessibilityPlayerUsesStackedLayout() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout") }
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-navigation", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
    app.launch()
    maximizeIPadWindow()
    let info = app.scrollViews["player-information"]
    XCTAssertTrue(info.waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["全屏"].isHittable)
    XCTAssertTrue(app.buttons["显示侧栏"].isHittable)
    revealIPadElement(app.buttons["video-favorite"], scroll: info)
    app.buttons["video-favorite"].tap()
    XCTAssertTrue(app.navigationBars["收藏"].waitForExistence(timeout: 5))
    attach("ipad-accessibility-favorites", app: app)
  }

  func testIPadNarrowWindowKeepsPlayerAndDetailsReachable() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout") }
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-navigation"]
    app.launch()
    maximizeIPadWindow()
    let info = app.scrollViews["player-information"]
    let surface = app.otherElements["player-viewport"].firstMatch
    XCTAssertTrue(info.waitForExistence(timeout: 15))
    let grabber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.99))
    let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.86))
    grabber.press(forDuration: 0.2, thenDragTo: target)
    XCTAssertTrue(app.buttons["显示侧栏"].waitForExistence(timeout: 8))
    XCTAssertLessThan(surface.frame.width, 700)
    XCTAssertTrue(app.buttons["全屏"].isHittable)
    revealIPadElement(app.staticTexts["player-title"], scroll: info)
    attach("ipad-narrow-window", app: app)
    app.buttons["显示侧栏"].tap()
    XCTAssertTrue(app.buttons["tablet-nav-history"].waitForExistence(timeout: 5))
    app.buttons["tablet-nav-history"].tap()
    XCTAssertTrue(app.navigationBars["观看记录"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["mini-player-open"].exists)
    maximizeIPadWindow()
  }

  private func revealIPadElement(_ element: XCUIElement, scroll: XCUIElement) {
    for _ in 0..<12 {
      if element.exists && element.isHittable
        && element.frame.minY >= scroll.frame.minY + 80
        && element.frame.maxY <= scroll.frame.maxY - 20 { break }
      scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(
        forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    }
    XCTAssertTrue(element.isHittable)
  }

  private func maximizeIPadWindow() {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let controls = springboard.buttons["window-controls:com.wzk112.BilibiliNEXT.iOS"]
    if controls.exists && controls.isHittable {
      controls.tap()
      let zoom = springboard.buttons["Zoom-button"]
      XCTAssertTrue(zoom.waitForExistence(timeout: 5))
      zoom.tap()
    }
  }

  private func goBack(_ app: XCUIApplication) {
    if app.buttons["BackButton"].exists {
      app.buttons["BackButton"].tap()
    } else {
      app.navigationBars.buttons.firstMatch.tap()
    }
  }

  private func checkMiniPlayer(_ app: XCUIApplication) {
    app.buttons["收起播放器"].tap()
    XCTAssertTrue(app.buttons["关闭播放器"].waitForExistence(timeout: 5))
    app.buttons["资料库"].tap()
    XCTAssertTrue(app.buttons["关闭播放器"].exists)
    attach("mini-player", app: app)
    app.buttons["关闭播放器"].tap()
    XCTAssertFalse(app.buttons["关闭播放器"].exists)
  }

  private func feedbackApp(refresh: Bool = false, sequences: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-ui-pages", "--qa-feed-retention", "-startPage", "recommend",
      "-hiddenNavigationItems", "", "-navigationItemOrder", "", "-showRecommended", "YES", "-showPopular", "YES", "-refreshHomeOnReturn", refresh ? "YES" : "NO"]
      + (sequences ? ["--qa-sequences"] : [])
    app.launch()
    if UIDevice.current.userInterfaceIdiom == .pad { maximizeIPadWindow() }
    XCTAssertTrue(app.buttons["video-card-BV1xx411c7mD"].waitForExistence(timeout: 15))
    return app
  }

  func testFeedbackReturnPreservesEachBrowsePosition() {
    if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = feedbackApp()
    for destination in ["推荐", "热门", "分区"] {
      if UIDevice.current.userInterfaceIdiom == .pad {
        let id = destination == "推荐" ? "recommend" : destination == "热门" ? "popular" : "regions"
        app.buttons["tablet-nav-" + id].tap()
      } else { app.buttons[destination].firstMatch.tap() }
      let scroll = app.scrollViews["browse-list"]
      XCTAssertTrue(scroll.waitForExistence(timeout: 10))
      for _ in 0..<3 { scroll.swipeUp() }
      let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-card-"))
      let visible = cards.allElementsBoundByIndex.filter { $0.frame.height > 0 && $0.frame.midY > 200 && $0.frame.maxY < app.frame.maxY - 160 && $0.isHittable }
      XCTAssertFalse(visible.isEmpty)
      guard let card = visible.first else { return }
      let id = card.identifier
      let y = card.frame.minY
      card.tap()
      XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 10))
      app.buttons["收起播放器"].tap()
      XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
      XCTAssertTrue(app.buttons[id].isHittable)
      XCTAssertEqual(app.buttons[id].frame.minY, y, accuracy: 5)
      XCTAssertFalse(app.buttons["video-card-BV1xx411c7mD"].isHittable)
      attach("feedback-return-" + destination, app: app)
      // The list must also survive switching away from its home container.
      if UIDevice.current.userInterfaceIdiom == .pad {
        app.buttons["tablet-nav-history"].tap()
        let dest = destination == "推荐" ? "recommend" : destination == "热门" ? "popular" : "regions"
        app.buttons["tablet-nav-" + dest].tap()
      } else {
        app.buttons["资料库"].tap(); app.buttons["首页"].tap()
      }
      XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
      XCTAssertEqual(app.buttons[id].frame.minY, y, accuracy: 5)
    }
  }

  func testFeedbackOptionalHomeRefreshReturnsToTop() {
    let app = feedbackApp(refresh: true)
    let scroll = app.scrollViews["browse-list"]
    scroll.swipeUp(); scroll.swipeUp()
    let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "video-card-")).allElementsBoundByIndex.first { $0.frame.height > 0 && $0.frame.midY > 200 && $0.frame.maxY < app.frame.maxY - 150 && $0.isHittable }!
    card.tap()
    XCTAssertTrue(app.buttons["收起播放器"].waitForExistence(timeout: 10))
    app.buttons["收起播放器"].tap()
    let first = app.buttons["video-card-BV1xx411c7mD"]
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    let refreshed = NSPredicate(format: "label CONTAINS %@ AND hittable == true", "刷新 2")
    expectation(for: refreshed, evaluatedWith: first)
    waitForExpectations(timeout: 10)
    attach("feedback-home-refreshed", app: app)
  }

  func testFeedbackPartsCollectionAndDanmakuPlacement() {
    let app = feedbackApp(sequences: true)
    app.buttons["video-card-BV1xx411c7mD"].tap()
    let input = app.textFields["danmaku-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    let viewport = app.descendants(matching: .any)["player-viewport"].firstMatch
    XCTAssertGreaterThanOrEqual(input.frame.minY, viewport.frame.maxY)
    XCTAssertLessThan(input.frame.minY - viewport.frame.maxY, 60)
    let parts = app.buttons["sequence-parts"]
    for _ in 0..<5 { if parts.isHittable { break }; app.swipeUp() }
    XCTAssertTrue(parts.isHittable)
    XCTAssertTrue(app.buttons["sequence-collection"].exists)
    parts.tap()
    XCTAssertTrue(app.navigationBars["分 P"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["P2 · 第二部分"].exists)
    attach("feedback-parts-sheet", app: app)
    app.buttons["完成"].tap()
    app.buttons["sequence-collection"].tap()
    XCTAssertTrue(app.navigationBars["合集 · 测试合集"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["合集下一视频"].exists)
    attach("feedback-collection-sheet", app: app)
  }

  func testFeedbackHiddenNavigationAndHistoryStartup() {
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-ui-pages", "-startPage", "history", "-showRecommended", "NO", "-showPopular", "NO"]
    app.launch()
    if UIDevice.current.userInterfaceIdiom == .pad { maximizeIPadWindow() }
    XCTAssertTrue(app.navigationBars["观看记录"].waitForExistence(timeout: 15))
    if UIDevice.current.userInterfaceIdiom == .pad {
      XCTAssertFalse(app.buttons["tablet-nav-recommend"].exists)
      XCTAssertFalse(app.buttons["tablet-nav-popular"].exists)
      app.buttons["设置"].tap()
    } else {
      app.buttons["首页"].tap()
      XCTAssertFalse(app.segmentedControls.buttons["推荐"].exists)
      XCTAssertFalse(app.segmentedControls.buttons["热门"].exists)
      app.buttons["我的"].tap(); app.buttons["设置"].tap()
    }
    XCTAssertTrue(app.switches["refresh-home-on-return"].waitForExistence(timeout: 8))
    attach("feedback-navigation-settings", app: app)
  }

  func testFeedbackCustomNavigationOrderAndSettingsRecovery() {
    if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--qa-ui", "--qa-ui-pages", "-startPage", "downloads",
      "-showRecommended", "YES", "-showPopular", "YES",
      "-hiddenNavigationItems", "recommend,popular,regions,dynamic,history,favorites,later,profile",
      "-navigationItemOrder", "downloads,messages"]
    app.launch()
    if UIDevice.current.userInterfaceIdiom == .pad { maximizeIPadWindow() }
    XCTAssertTrue(app.navigationBars["下载"].waitForExistence(timeout: 15))
    if UIDevice.current.userInterfaceIdiom == .pad {
      XCTAssertFalse(app.buttons["tablet-nav-recommend"].exists)
      XCTAssertFalse(app.buttons["tablet-nav-history"].exists)
      XCTAssertTrue(app.buttons["tablet-nav-downloads"].exists)
      XCTAssertTrue(app.buttons["tablet-nav-messages"].exists)
      app.buttons["设置"].tap()
    } else {
      XCTAssertFalse(app.tabBars.buttons["首页"].exists)
      XCTAssertFalse(app.tabBars.buttons["动态"].exists)
      let library = app.tabBars.buttons["资料库"]
      let messages = app.tabBars.buttons["消息"]
      XCTAssertLessThan(library.frame.minX, messages.frame.minX)
      app.tabBars.buttons["设置"].tap()
    }
    XCTAssertTrue(app.switches["refresh-home-on-return"].waitForExistence(timeout: 8))
    app.buttons["自定义导航项目"].tap()
    XCTAssertTrue(app.switches["show-downloads"].waitForExistence(timeout: 5))
    attach("custom-navigation-recovery", app: app)
  }

  func testTabletSidebarResetsPushedDetailWithoutExtraBack() throws {
    try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad)
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = feedbackApp()
    for target in ["热门", "设置"] {
      app.buttons["tablet-settings"].tap()
      XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
      let license = app.buttons["开源许可"]
      for _ in 0..<15 { if license.exists && license.isHittable { break }; app.swipeUp() }
      XCTAssertTrue(license.isHittable)
      license.tap()
      XCTAssertTrue(app.navigationBars["开源许可"].waitForExistence(timeout: 5))
      if target == "热门" { app.buttons["tablet-nav-popular"].tap() }
      else { app.buttons["tablet-settings"].firstMatch.tap() }
      if target == "热门" {
        XCTAssertTrue(app.staticTexts["tablet-page-heading"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["tablet-page-heading"].label, "热门")
      } else { XCTAssertTrue(app.navigationBars[target].waitForExistence(timeout: 5)) }
      XCTAssertFalse(app.navigationBars["开源许可"].exists)
      if target == "热门" { XCTAssertTrue(app.scrollViews["browse-list"].exists) }
      attach("tablet-sidebar-clears-detail-" + target, app: app)
    }
  }

  func testTabletHomeHeaderVisibleWithoutPullingDown() throws {
    try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad)
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = feedbackApp()
    for (key, title) in [("recommend", "推荐"), ("popular", "热门"), ("regions", "分区")] {
      app.buttons["tablet-nav-" + key].tap()
      let heading = app.staticTexts["tablet-page-heading"]
      XCTAssertTrue(heading.waitForExistence(timeout: 5))
      XCTAssertEqual(heading.label, title)
      attach("tablet-initial-header-" + key, app: app)
      XCTAssertTrue(heading.isHittable)
      XCTAssertGreaterThanOrEqual(heading.frame.height, 30, "Large title should be visible before pulling down")
      let first = app.buttons["video-card-BV1xx411c7mD"]
      XCTAssertTrue(first.isHittable)
      XCTAssertGreaterThanOrEqual(first.frame.minY, heading.frame.maxY)
      let scroll = app.scrollViews["browse-list"]
      scroll.swipeUp(); scroll.swipeUp()
      XCTAssertTrue(heading.isHittable)
      XCTAssertGreaterThanOrEqual(heading.frame.height, 28, "iPad title should stay visible at desktop size while scrolled")
      attach("tablet-scrolled-header-" + key, app: app)
    }
    XCUIDevice.shared.orientation = .portrait
    let heading = app.staticTexts["tablet-page-heading"]
    XCTAssertTrue(heading.waitForExistence(timeout: 5))
    XCTAssertTrue(heading.isHittable)
    attach("tablet-header-portrait", app: app)
    let search = app.textFields["tablet-search"]
    search.tap()
    search.typeText("layout")
    XCTAssertTrue(heading.isHittable)
    XCTAssertTrue(app.buttons["显示侧栏"].exists)
    attach("tablet-keyboard-stable-layout", app: app)
  }

  func testTabletShortSidebarScrollKeepsHeaderAndAccountSeparate() throws {
    try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .pad)
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = feedbackApp()
    let grabber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.99))
    grabber.press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.64)))
    let scroll = app.scrollViews["tablet-navigation-scroll-library"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["tablet-nav-recommend"].isHittable)
    scroll.swipeUp(); scroll.swipeUp()
    XCTAssertTrue(app.buttons["tablet-nav-profile"].isHittable)
    XCTAssertTrue(app.buttons["tablet-account"].isHittable)
    XCTAssertFalse(app.buttons["tablet-nav-history"].isHittable)
    attach("tablet-short-sidebar-scrolled", app: app)
    maximizeIPadWindow()
  }

  private func attach(_ name: String, app: XCUIApplication) {
    // App-only screenshots can be cropped with stale orientation after iPad window resizing.
    let screenshot = UIDevice.current.userInterfaceIdiom == .pad
      ? XCUIScreen.main.screenshot() : app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
  private func waitForValue(
    _ id: String, _ value: String, app: XCUIApplication, timeout: TimeInterval = 20
  ) -> Bool {
    let element = app.descendants(matching: .any)[id].firstMatch
    guard element.waitForExistence(timeout: 5) else { return false }
    return XCTWaiter.wait(
      for: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", value), object: element)
      ], timeout: timeout) == .completed
  }
}
