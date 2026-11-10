import CFNetwork
import Foundation
import Synchronization
import Testing
@testable import BiliGlass

private final class ProxyPreference: Sendable {
  let value = Mutex(false)
  func set(_ bypass: Bool) { value.withLock { $0 = bypass } }
  func get() -> Bool { value.withLock { $0 } }
}

@Suite struct BiliNetworkPolicyTests {
  @Test func exceptionsPreserveSystemProxyAndDoNotBypassUnrelatedHosts() throws {
    let key = kCFNetworkProxiesExceptionsList as String
    let original: [AnyHashable: Any] = [
      "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
      "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
      key: ["localhost", "*.private.test"],
    ]
    let settings = try #require(BiliNetworkPolicy.proxySettings(bypass: true, system: original))
    #expect(settings["HTTPEnable"] as? Int == 1)
    #expect(settings["HTTPProxy"] as? String == "127.0.0.1")
    #expect(settings["HTTPSPort"] as? Int == 7890)
    let exceptions = try #require(settings[key] as? [String])
    #expect(exceptions.contains("localhost"))
    #expect(exceptions.contains("*.private.test"))
    for host in ["api.bilibili.com", "passport.bilibili.com", "i0.hdslb.com", "upos-sz.bilivideo.com", "a.b.bilivideo.cn"] {
      let proxies = CFNetworkCopyProxiesForURL(URL(string: "https://" + host)! as CFURL,
        settings as CFDictionary).takeRetainedValue() as? [[String: Any]]
      #expect(proxies?.first?[kCFProxyTypeKey as String] as? String == kCFProxyTypeNone as String)
    }
    let proxies = CFNetworkCopyProxiesForURL(URL(string: "https://unrelated.test")! as CFURL,
      settings as CFDictionary).takeRetainedValue() as? [[String: Any]]
    #expect(proxies?.first?[kCFProxyTypeKey as String] as? String != kCFProxyTypeNone as String)
    #expect(BiliNetworkPolicy.proxySettings(bypass: false, system: original) == nil)
  }

  @Test func switchingEitherDirectionReplacesConnectionsAndPreservesSessionConfiguration() throws {
    let preference = ProxyPreference()
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.timeoutIntervalForRequest = 19
    let network = BiliNetworkSession(configuration: config, bypass: { preference.get() })
    let proxied = network.session
    #expect(proxied === network.session)
    #expect(proxied.configuration.connectionProxyDictionary == nil)
    preference.set(true)
    let direct = network.session
    #expect(direct !== proxied)
    #expect(direct === network.session)
    #expect(direct.configuration.connectionProxyDictionary != nil)
    #expect(direct.configuration.httpCookieStorage == nil)
    #expect(!direct.configuration.httpShouldSetCookies)
    #expect(direct.configuration.timeoutIntervalForRequest == 19)
    preference.set(false)
    let restored = network.session
    #expect(restored !== direct && restored !== proxied)
    #expect(restored.configuration.connectionProxyDictionary == nil)
  }
}
