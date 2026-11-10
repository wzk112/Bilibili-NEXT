import SwiftUI
import WebKit

/// The official SDK presents the server-supplied challenge. The user starts and
/// completes it; neither this view nor its completion handler submits a coin.
struct OfficialChallengeView: View {
  let api: API
  let challenge: InteractionChallenge
  let completed: () -> Void
  @State private var error: String?
  var body: some View {
    VStack(spacing: 12) {
      Text("完成哔哩哔哩验证后，返回确认本次操作。").font(.callout)
      Text("验证本身不会投币。").font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
      OfficialChallengeWeb(api: api, challenge: challenge, completed: completed, error: $error)
        .frame(minHeight: 360)
    }.padding(16)
  }
}

@MainActor private struct OfficialChallengeWeb {
  let api: API
  let challenge: InteractionChallenge
  let completed: () -> Void
  @Binding var error: String?
  func makeCoordinator() -> OfficialChallengeCoordinator {
    OfficialChallengeCoordinator(api: api, challenge: challenge, completed: completed, error: $error)
  }
}
#if os(macOS)
extension OfficialChallengeWeb: NSViewRepresentable {
  func makeNSView(context: Context) -> WKWebView { context.coordinator.makeView() }
  func updateNSView(_ view: WKWebView, context: Context) {}
  static func dismantleNSView(_ view: WKWebView, coordinator: OfficialChallengeCoordinator) { coordinator.stop(view) }
}
#else
extension OfficialChallengeWeb: UIViewRepresentable {
  func makeUIView(context: Context) -> WKWebView { context.coordinator.makeView() }
  func updateUIView(_ view: WKWebView, context: Context) {}
  static func dismantleUIView(_ view: WKWebView, coordinator: OfficialChallengeCoordinator) { coordinator.stop(view) }
}
#endif

@MainActor final class OfficialChallengeCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  let api: API
  let challenge: InteractionChallenge
  let completed: () -> Void
  private let webSession: WebSession
  @Binding var error: String?
  var task: Task<Void, Never>?
  var active = true
  var accepted = false
  init(api: API, challenge: InteractionChallenge, completed: @escaping () -> Void, error: Binding<String?>, webSession: WebSession? = nil) {
    self.api = api; self.challenge = challenge; self.completed = completed; _error = error
    self.webSession = webSession ?? .shared
  }
  func makeView() -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = webSession.dataStore
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.userContentController.add(self, name: "officialVerification")
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.customUserAgent = API.userAgent
    view.navigationDelegate = self
    task = Task { @MainActor [weak self, weak view] in
      guard let self, let view else { return }
      await webSession.prepare(api: api)
      guard !Task.isCancelled, active, api.authenticationGeneration == challenge.authentication else { return }
      view.loadHTMLString(Self.html, baseURL: URL(string: "https://www.bilibili.com/"))
    }
    return view
  }
  func stop(_ view: WKWebView) {
    active = false; task?.cancel(); view.stopLoading()
    view.configuration.userContentController.removeScriptMessageHandler(forName: "officialVerification")
    view.navigationDelegate = nil
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard active, api.authenticationGeneration == challenge.authentication,
      let payload = try? JSONSerialization.jsonObject(with: challenge.payload) else { return }
    task = Task { @MainActor [weak self, weak webView] in
      do {
        _ = try await webView?.callAsyncJavaScript(
          "window.verificationOptions = options; window.verificationDiagnostics = diagnostics; document.getElementById('start').disabled = false;",
          arguments: ["options": payload, "diagnostics": ProcessInfo.processInfo.arguments.contains("--full-coin-check")], in: nil, contentWorld: .page)
      } catch { self?.error = "验证页面加载失败，请关闭后重试" }
    }
  }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let url = action.request.url
    let allowed = url?.scheme == "about" || (url?.scheme == "https" &&
      (action.targetFrame?.isMainFrame == false || url?.host == "www.bilibili.com"))
    decisionHandler(allowed ? .allow : .cancel)
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard active, !accepted, message.frameInfo.isMainFrame,
      message.frameInfo.securityOrigin.host == "www.bilibili.com",
      api.authenticationGeneration == challenge.authentication,
      let body = message.body as? [String: String] else { return }
    if body["status"] == "diagnostic" {
      let args = ProcessInfo.processInfo.arguments
      if let i = args.firstIndex(of: "--full-coin-check"), args.indices.contains(i + 2),
         let data = body["responses"]?.data(using: .utf8) {
        try? data.write(to: URL(fileURLWithPath: args[i + 2]).appendingPathExtension("verification-stages.json"), options: .atomic)
      }
      return
    }
    if body["status"] == "started" { error = nil; return }
    if body["status"] == "incomplete" {
      let reason = body["reason"] ?? ""
      switch reason {
      case "expired": error = "验证码已过期，请关闭后重新打开验证"
      case "limit", "execeedLimit": error = "验证请求过于频繁，请稍后再试"
      case "offline", "timeout": error = "验证连接中断或超时，请稍后重试"
      case "captchaCanceled": error = "已取消验证"
      case "invalidFail": error = "验证未通过，请重试"
      case "csrfMissing": error = "验证会话未准备好，请关闭后重新打开验证"
      case "componentError": error = "验证组件处理结果时出错，请关闭后在官网继续操作"
      case "getFail", "retry": error = "官方验证服务暂时未接受本次验证，请稍后重试"
      default: error = "验证未完成，请重试或关闭后在官网操作"
      }
      // Only diagnostic codes, never tokens, cookies, URLs or SDK error text.
      let args = ProcessInfo.processInfo.arguments
      if let i = args.firstIndex(of: "--full-coin-check"), args.indices.contains(i + 2) {
        let safe = ["reason": reason, "code": body["code"] ?? "", "stage": body["stage"] ?? "",
                    "csrfReadable": body["csrfReadable"] ?? "", "phase": body["phase"] ?? "",
                    "failureClass": body["failureClass"] ?? "", "resultType": body["resultType"] ?? "",
                    "resultFields": body["resultFields"] ?? "", "failureKind": body["failureKind"] ?? "",
                    "responses": body["responses"] ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .prettyPrinted]) {
          try? data.write(to: URL(fileURLWithPath: args[i + 2]).appendingPathExtension("verification-error.json"), options: .atomic)
        }
      }
      return
    }
    guard body["status"] == "success", let token = body["token"],
      api.acceptVerification(token, for: challenge) else {
      error = "验证未完成，请重试或关闭后在官网操作"; return
    }
    accepted = true
    completed()
  }
  private static let html = """
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{margin:0;font:16px -apple-system,sans-serif;background:#f7f7fa;color:#222}
    main{text-align:center;padding:40px 16px}button{padding:12px 24px;border:0;border-radius:12px;background:#d9366b;color:white;font:inherit;cursor:pointer}
    p{font-size:14px;color:#666}button:disabled{opacity:.5}</style></head><body>
    <main><button id="start" disabled>开始官方验证</button><p id="status">请由你完成验证</p></main>
    <script>
    const responses = [];
    const originalFetch = window.fetch.bind(window);
    window.fetch = async function (input, init) {
      const url = new URL(typeof input === 'string' ? input : input.url, location.href);
      const observed = window.verificationDiagnostics && url.origin === 'https://api.bilibili.com' &&
        /^\\/x\\/gaia-vgate\\/v[12]\\/(register|validate|validatePreCheck|retry)$/.test(url.pathname);
      const response = await originalFetch(input, init);
      if (observed) {
        const row = {stage:url.pathname.split('/').pop(), status:response.status};
        try {
          const body = await response.clone().json();
          if (Number.isInteger(body.code)) row.code = body.code;
          if ([0,1].includes(body.data?.is_valid)) row.valid = body.data.is_valid;
          if (['geetest','geetest4','biliword','img','phone','sms','login','sms_mo','realname','live_detect'].includes(body.data?.type)) row.type = body.data.type;
        } catch (_) {}
        responses.push(row); if (responses.length > 8) responses.shift();
        window.webkit.messageHandlers.officialVerification.postMessage({status:'diagnostic',responses:JSON.stringify(responses)});
      }
      return response;
    };
    document.getElementById('start').onclick = async function () {
      this.disabled = true; document.getElementById('status').textContent = '正在加载官方验证…';
      window.webkit.messageHandlers.officialVerification.postMessage({status:'started'});
      let phase = 'loading', resultType = '', resultFields = '';
      try {
        if (!document.cookie.split(';').some(value => value.trim().startsWith('bili_jct='))) {
          throw {tipKey:'csrfMissing'};
        }
        if (!window.CaptchaLoader) await new Promise((resolve, reject) => {
          const script = document.createElement('script');
          script.src = 'https://s1.hdslb.com/bfs/seed/jinkela/risk-captcha-sdk/CaptchaLoader.js';
          script.onload = resolve; script.onerror = reject; document.head.appendChild(script);
        });
        const verify = await window.CaptchaLoader.load();
        phase = 'verifying';
        const token = await verify(window.verificationOptions);
        phase = 'result'; resultType = typeof token;
        resultFields = token && typeof token === 'object' ? Object.keys(token).filter(k => /^[a-zA-Z_]{1,32}$/.test(k)).join(',') : '';
        if (typeof token !== 'string' || !token) throw new Error('incomplete');
        document.getElementById('status').textContent = '验证完成，返回后请再次确认操作';
        phase = 'handoff';
        window.webkit.messageHandlers.officialVerification.postMessage({status:'success',token});
      } catch (failure) {
        const reasons = ['getFail','retry','expired','limit','execeedLimit','offline','timeout','captchaCanceled','invalidFail','csrfMissing'];
        const componentError = ['TypeError','ReferenceError','SyntaxError'].includes(failure?.name);
        const reason = componentError ? 'componentError' : reasons.includes(failure?.tipKey) ? failure.tipKey : 'unknown';
        this.disabled = componentError;
        document.getElementById('status').textContent = componentError ? '验证组件出错，请关闭后在官网继续' : '未能取得官方确认，请稍后重试';
        const code = Number.isInteger(failure?.code) ? String(failure.code) : '';
        const stage = /\\/(register|validate|validatePreCheck|retry)$/.exec(failure?.apiName || '')?.[1] || '';
        const classes = ['Error','TypeError','ReferenceError','SyntaxError','apiError','serverError','invalid','expired','cancel','timeout','offline'];
        const failureClass = classes.includes(failure?.name) ? failure.name : typeof failure;
        const failureKind = failure?.message === 'incomplete' ? 'missingToken' :
          /is not a function/.test(failure?.message || '') ? 'notCallable' :
          /undefined|null/.test(failure?.message || '') ? 'missingValue' : 'other';
        window.webkit.messageHandlers.officialVerification.postMessage({status:'incomplete',reason,code,stage,phase,resultType,resultFields,failureClass,failureKind,
          responses:JSON.stringify(responses),
          csrfReadable:String(document.cookie.split(';').some(value => value.trim().startsWith('bili_jct=')))});
      }
    };
    </script></body></html>
    """
}
