import Testing
import WebKit
import SwiftUI
@testable import BiliGlass

@MainActor struct VerificationWebTests {
  @Test func sdkRuntimeFailureDoesNotGrantVerificationOrAskForAnotherCaptcha() async throws {
    let api = API(loadCredentials: false)
    api.cookies = ["SESSDATA": "fixture-session", "bili_jct": "fixture-csrf"]
    let challenge = InteractionChallenge(code: -401, payload: Data("{}".utf8),
      path: "/x/web-interface/coin/add", body: ["csrf": "fixture-csrf"], authentication: api.authenticationGeneration)
    var completed = false
    var failure: String?
    let coordinator = OfficialChallengeCoordinator(api: api, challenge: challenge, completed: { completed = true },
      error: Binding(get: { failure }, set: { failure = $0 }), webSession: WebSession())
    let view = coordinator.makeView()
    defer { coordinator.stop(view) }
    for _ in 0..<100 {
      if (try? await view.evaluateJavaScript("document.getElementById('start')?.disabled === false")) as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    _ = try await view.evaluateJavaScript("window.CaptchaLoader = {load: async () => async () => {throw new TypeError('fixture call is not a function')}}; document.getElementById('start').click(); true;")
    for _ in 0..<100 {
      if failure != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(!completed)
    #expect(api.interactionVerification == nil)
    #expect(failure == "验证组件处理结果时出错，请关闭后在官网继续操作")
    #expect(try await view.evaluateJavaScript("document.getElementById('start').disabled") as? Bool == true)
  }
  @Test func officialResultReachesTheNativeGrantWithoutSubmittingAWritingRequest() async throws {
    let api = API(loadCredentials: false)
    api.cookies = ["SESSDATA": "fixture-session", "bili_jct": "fixture-csrf"]
    let challenge = InteractionChallenge(code: -401, payload: Data("{}".utf8),
      path: "/x/web-interface/coin/add", body: ["csrf": "fixture-csrf"], authentication: api.authenticationGeneration)
    var completed = false
    var failure: String?
    let coordinator = OfficialChallengeCoordinator(api: api, challenge: challenge, completed: { completed = true },
      error: Binding(get: { failure }, set: { failure = $0 }), webSession: WebSession())
    let view = coordinator.makeView()
    defer { coordinator.stop(view) }
    for _ in 0..<100 {
      if (try? await view.evaluateJavaScript("document.getElementById('start')?.disabled === false")) as? Bool == true { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    // Test a local SDK fixture only: no actual verification request or challenge.
    _ = try await view.evaluateJavaScript("window.CaptchaLoader = {load: async () => async () => 'fixture-grant'}; document.getElementById('start').click(); true;")
    for _ in 0..<100 {
      if completed { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(completed)
    #expect(failure == nil)
    #expect(api.interactionVerification?.token == "fixture-grant")
  }
  @Test func verificationDocumentCanReadCSRFWithoutExposingSessionCookie() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let cookies = configuration.websiteDataStore.httpCookieStore
    await cookies.setCookie(try #require(WebSession.cookie(name: "bili_jct", value: "fixture-csrf")))
    await cookies.setCookie(try #require(WebSession.cookie(name: "SESSDATA", value: "fixture-session")))
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.loadHTMLString("<html><body><script>window.fixtureReady = true;</script></body></html>",
                        baseURL: URL(string: "https://www.bilibili.com/"))
    defer { view.stopLoading() }
    var ready = false
    for _ in 0..<100 {
      if (try? await view.evaluateJavaScript("window.fixtureReady === true")) as? Bool == true {
        ready = true; break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(ready)
    let cookie = try #require(try await view.evaluateJavaScript("document.cookie") as? String)
    #expect(cookie.contains("bili_jct=fixture-csrf"))
    #expect(!cookie.contains("SESSDATA"))
    #expect(try await view.evaluateJavaScript("location.origin") as? String == "https://www.bilibili.com")
  }
}
