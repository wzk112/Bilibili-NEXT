import SwiftUI
import WebKit

struct WebTarget: Identifiable {
  let id = UUID()
  let url: URL
  let title: String
}
@MainActor final class WebSession {
  static let shared = WebSession()
  let dataStore = WKWebsiteDataStore.nonPersistent()
  static func cookie(name: String, value: String) -> HTTPCookie? {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .domain: ".bilibili.com", .path: "/", .name: name, .value: value, .secure: "TRUE",
    ]
    // Foundation treats the presence of HttpOnly as true, even for "FALSE".
    // The website must read bili_jct to include its CSRF value in form posts.
    if name == "SESSDATA" { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    return HTTPCookie(properties: properties)
  }
  func prepare(api: API) async {
    for (name, value) in api.cookies {
      guard let cookie = Self.cookie(name: name, value: value) else { continue }
      await dataStore.httpCookieStore.setCookie(cookie)
    }
  }
  func reset() {
    dataStore.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast,
      completionHandler: {})
  }
}
@MainActor @Observable final class WebState {
  var loading = true
  var error: String?
  var url: URL?
  var canGoBack = false
  var webView: WKWebView?
}
struct OfficialWebPanel: View {
  let target: WebTarget
  let api: API
  @State private var state = WebState()
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(target.title).font(.headline)
        Spacer()
        if state.loading { ProgressView().controlSize(.small) }
        Button("重新加载") { state.webView?.reload() }.buttonStyle(.appGlassButton)
      }.padding(14)
      if let error = state.error {
        ErrorBanner(text: error) { state.webView?.reload() }.padding(12)
      }
      OfficialWebView(target: target, api: api, state: state)
    }.background { GlassBackdrop() }
  }
}
struct OfficialWebView: NSViewRepresentable {
  let target: WebTarget
  let api: API
  let state: WebState
  func makeCoordinator() -> Coordinator { Coordinator(api: api, state: state) }
  func makeNSView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = WebSession.shared.dataStore
    config.mediaTypesRequiringUserActionForPlayback = .all
    let view = WKWebView(frame: .zero, configuration: config)
    view.customUserAgent = API.userAgent
    view.navigationDelegate = context.coordinator
    view.uiDelegate = context.coordinator
    view.allowsBackForwardNavigationGestures = true
    state.webView = view
    context.coordinator.observation = view.observe(\.estimatedProgress, options: [.new]) {
      [weak state] view, _ in
      Task { @MainActor in
        state?.loading = view.isLoading
        state?.canGoBack = view.canGoBack
        state?.url = view.url
      }
    }
    config.websiteDataStore.httpCookieStore.add(context.coordinator)
    context.coordinator.loadTask = Task { @MainActor in
      await WebSession.shared.prepare(api: api)
      guard !Task.isCancelled else { return }
      view.load(URLRequest(url: target.url))
    }
    return view
  }
  func updateNSView(_ view: WKWebView, context: Context) {}
  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    coordinator.loadTask?.cancel()
    view.stopLoading()
    view.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
    coordinator.observation = nil
    coordinator.state.webView = nil
  }
  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    let api: API
    let generation: UUID
    let state: WebState
    var observation: NSKeyValueObservation?
    var loadTask: Task<Void, Never>?
    init(api: API, state: WebState) {
      self.api = api
      self.generation = api.authenticationGeneration
      self.state = state
    }
    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }
      if navigationAction.targetFrame?.isMainFrame == false && url.scheme == "https" {
        decisionHandler(.allow)
        return
      }
      if url.scheme == "about" {
        decisionHandler(.allow)
        return
      }
      guard url.scheme == "https", let host = url.host,
        host == "bilibili.com" || host.hasSuffix(".bilibili.com") || host == "biligame.com"
          || host.hasSuffix(".biligame.com")
      else {
        if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
        return
      }
      decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
      state.loading = true
      state.error = nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      state.loading = false
      state.url = webView.url
      state.canGoBack = webView.canGoBack
      cookiesDidChange(in: webView.configuration.websiteDataStore.httpCookieStore)
    }
    func webView(
      _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: Error
    ) {
      if (error as NSError).code != NSURLErrorCancelled {
        state.loading = false
        state.error = error.localizedDescription
      }
    }
    func webView(
      _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
      return nil
    }
    func webView(
      _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void
    ) {
      let a = NSAlert()
      a.messageText = message
      a.runModal()
      completionHandler()
    }
    func webView(
      _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
      initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void
    ) {
      let a = NSAlert()
      a.messageText = message
      a.addButton(withTitle: "确定")
      a.addButton(withTitle: "取消")
      completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
      cookieStore.getAllCookies { [weak self] cookies in
        Task { @MainActor in
          guard let self, self.api.authenticationGeneration == self.generation else { return }
          let auth = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"]
          var authChanged = false
          for c in cookies where c.domain == ".bilibili.com" || c.domain == "bilibili.com" {
            if auth.contains(c.name) {
              if self.api.cookies[c.name] != c.value {
                self.api.cookies[c.name] = c.value
                authChanged = true
              }
            } else if API.interactionCookieNames.contains(c.name), c.expiresDate.map({ $0 > Date() }) ?? true {
              self.api.cookies[c.name] = c.value
            }
          }
          if authChanged {
            let saved = self.api.cookies.filter { auth.contains($0.key) }
            if let data = try? JSONEncoder().encode(saved) { try? Vault.save(data) }
          }
        }
      }
    }
  }
}

struct WebFunctionsPage: View {
  @Bindable var store: Store
  @State private var showBlacklist = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("更多").font(.title2.bold())
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
          ForEach([Destination.messages, .dynamic, .profile, .downloads], id: \.self) {
            destination in
            Button {
              store.navigate(destination)
            } label: {
              Label(destination.rawValue, systemImage: destination.icon).frame(
                maxWidth: .infinity, alignment: .leading
              ).padding(22).floatingGlass(22)
            }.buttonStyle(.plain)
          }
          SettingsLink {
            Label("应用设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
              .padding(22).floatingGlass(22)
          }.buttonStyle(.plain)
          Button { showBlacklist = true } label: {
            Label("黑名单", systemImage: "person.slash").frame(maxWidth: .infinity, alignment: .leading).padding(22).floatingGlass(22)
          }.buttonStyle(.plain).disabled(store.account == nil)
        }
        VStack(alignment: .leading, spacing: 16) {
          Text("哔哩哔哩服务").font(.headline)
          Link("创作中心", destination: URL(string: "https://member.bilibili.com/platform/home")!)
          Link("番剧", destination: URL(string: "https://www.bilibili.com/anime/")!)
          Link("直播", destination: URL(string: "https://live.bilibili.com/")!)
          Text("这些服务在默认浏览器中打开。").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).floatingGlass(24)
      }.padding(AppLayout.pageInset).padding(.vertical, 8)
    }.sheet(isPresented: $showBlacklist) { BlockedAuthorsPage(store: store) }
  }
}
