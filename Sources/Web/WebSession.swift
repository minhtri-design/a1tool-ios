import SwiftUI
import WebKit

/// Các đoạn JavaScript chạy trong trang.
enum WebJS {
    /// Chạy từ lúc trang bắt đầu tải: bắt header X-Auth-Token của các lệnh gọi API.
    static let tokenHook = #"""
    (function(){
      try {
        if (window.__a1Hooked) return;
        window.__a1Hooked = true;
        var oSet = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.setRequestHeader = function(k, v){
          try { if (String(k).toLowerCase() === 'x-auth-token' && v) { window.__a1Token = String(v); } } catch(e){}
          return oSet.apply(this, arguments);
        };
        var oFetch = window.fetch;
        if (oFetch) {
          window.fetch = function(input, init){
            try {
              var h = (init && init.headers) ? init.headers : null;
              if (h) {
                if (typeof h.get === 'function') {
                  var t = h.get('X-Auth-Token');
                  if (t) { window.__a1Token = String(t); }
                } else {
                  for (var k in h) {
                    if (String(k).toLowerCase() === 'x-auth-token' && h[k]) { window.__a1Token = String(h[k]); }
                  }
                }
              }
            } catch(e){}
            return oFetch.apply(this, arguments);
          };
        }
      } catch(e){}
    })();
    """#

    /// Đọc token đã bắt được (hoặc tìm trong localStorage/sessionStorage). Không có -> null.
    static let docToken = #"""
    (function(){
      try { if (window.__a1Token) return window.__a1Token; } catch(e){}
      try {
        var stores = [window.localStorage, window.sessionStorage];
        for (var s = 0; s < stores.length; s++) {
          var st = stores[s];
          for (var i = 0; i < st.length; i++) {
            var key = st.key(i);
            var val = st.getItem(key);
            if (!val) { continue; }
            if (/token/i.test(key) && val.length > 20 && val.length < 4000 && val.indexOf(' ') < 0 && val.charAt(0) !== '{' && val.charAt(0) !== '"') { return val; }
            if (val.charAt(0) === '{') {
              try {
                var o = JSON.parse(val);
                var t = o.token || o.accessToken || o.authToken || o['X-Auth-Token'];
                if (t && typeof t === 'string') { return t; }
              } catch(e){}
            }
          }
        }
      } catch(e){}
      return null;
    })()
    """#

    /// Nhận diện trang đăng nhập Cognito: ô tài khoản/mật khẩu hay ô mã MFA. Trả chuỗi JSON.
    static let detect = #"""
    (function(){
      function hien(o){ var s = getComputedStyle(o); if (s.display === 'none' || s.visibility === 'hidden') { return false; } var r = o.getBoundingClientRect(); return r.width > 0 && r.height > 0; }
      function first(sel){ var l = document.querySelectorAll(sel); for (var i = 0; i < l.length; i++) { if (hien(l[i])) { return l[i]; } } return null; }
      var u = first('input[name="username"], input#signInFormUsername, input[type="email"]');
      var p = first('input[name="password"], input[type="password"]');
      var m = first('input[name="confirmationCode"], input[name="totpCode"], input#totpCodeInput, input[autocomplete="one-time-code"], input[name="code"]');
      if (m) { m.setAttribute('data-a1', 'code'); return JSON.stringify({loai: 'mfa'}); }
      if (p) { p.setAttribute('data-a1', 'pass'); if (u) { u.setAttribute('data-a1', 'user'); } return JSON.stringify({loai: 'login', co_user: !!u}); }
      if (location.href.indexOf('/mfa') >= 0) { return JSON.stringify({loai: 'mfa'}); }
      return JSON.stringify({loai: 'none'});
    })()
    """#

    /// Điền giá trị vào ô có data-a1 = k. Tham số: k, t.
    static let fill = #"""
    var e = document.querySelector('[data-a1="' + k + '"]');
    if (!e) { return false; }
    if (e.focus) { e.focus(); }
    var d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    d.set.call(e, t);
    e.dispatchEvent(new Event('input', {bubbles: true}));
    e.dispatchEvent(new Event('change', {bubbles: true}));
    return e.value === t;
    """#

    /// Bấm nút Sign in / Submit; không có nút thì submit form của ô k.
    static let submit = #"""
    function hien(o){ var s = getComputedStyle(o); if (s.display === 'none' || s.visibility === 'hidden') { return false; } var r = o.getBoundingClientRect(); return r.width > 0 && r.height > 0; }
    var xp = '//button[@name="signInSubmitButton" or @type="submit" or normalize-space(.)="Sign in" or normalize-space(.)="Submit"] | //input[@type="submit"]';
    var it = document.evaluate(xp, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
    for (var i = 0; i < it.snapshotLength; i++) {
      var b = it.snapshotItem(i);
      if (hien(b) && !b.disabled) { b.click(); return true; }
    }
    var e = document.querySelector('[data-a1="' + k + '"]');
    if (e && e.form) { if (e.form.requestSubmit) { e.form.requestSubmit(); } else { e.form.submit(); } return true; }
    return false;
    """#

    /// fetch POST trong trang. Tham số: tok, url, body (chuỗi JSON hoặc null).
    static let fetch = #"""
    try {
      var h = {'Accept': 'application/json, text/plain, */*', 'Accept-Language': 'vn', 'X-Auth-Token': tok};
      if (body !== null) { h['Content-Type'] = 'application/json'; }
      var r = await fetch(url, {method: 'POST', headers: h, body: (body === null ? undefined : body), credentials: 'same-origin'});
      var t = await r.text();
      return JSON.stringify({status: r.status, text: t});
    } catch (e) {
      return JSON.stringify({status: 0, error: String(e)});
    }
    """#
}

enum LoginPage {
    case login(hasUser: Bool)
    case mfa
    case none
}

/// Trình duyệt nhúng (WKWebView): người dùng đăng nhập A1-Stream ở đây, app lấy token + cookie từ đó.
@MainActor
final class WebSession: NSObject, ObservableObject {
    static let shared = WebSession()

    let webView: WKWebView

    private override init() {
        let cfg = WKWebViewConfiguration()
        let hook = WKUserScript(source: WebJS.tokenHook, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        cfg.userContentController.addUserScript(hook)
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        self.webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        self.webView.allowsBackForwardNavigationGestures = true
    }

    // MARK: Tiện ích

    func currentURL() -> String {
        return webView.url?.absoluteString ?? ""
    }

    func load(_ urlString: String) {
        if let u = URL(string: urlString) { webView.load(URLRequest(url: u)) }
    }

    func reload() {
        if webView.url == nil { load(Rules.targetURL) } else { webView.reload() }
    }

    func ensureLoaded() {
        if webView.url == nil { load(Rules.targetURL) }
    }

    func js(_ code: String) async -> Any? {
        return await withCheckedContinuation { (c: CheckedContinuation<Any?, Never>) in
            webView.evaluateJavaScript(code) { result, _ in
                c.resume(returning: result)
            }
        }
    }

    func callJS(_ body: String, _ args: [String: Any] = [:]) async -> (Any?, String?) {
        return await withCheckedContinuation { (c: CheckedContinuation<(Any?, String?), Never>) in
            webView.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
                switch result {
                case .success(let v):
                    c.resume(returning: (v, nil))
                case .failure(let e):
                    c.resume(returning: (nil, e.localizedDescription))
                }
            }
        }
    }

    // MARK: fetch trong trang (kênh dự phòng)

    func fetch(path: String, body: JSON?, token: String) async -> RawResult {
        var bodyArg: Any = NSNull()
        if let b = body, let d = toJSONData(b), let s = String(data: d, encoding: .utf8) { bodyArg = s }
        let args: [String: Any] = ["tok": token, "url": Rules.apiRoot + path, "body": bodyArg]
        let (v, err) = await callJS(WebJS.fetch, args)
        guard let s = v as? String, let o = parseJSON(s) as? JSON else {
            return RawResult(status: 0, text: "", error: err ?? "không đọc được phản hồi từ trang")
        }
        let st = Int(soThuc(o["status"]) ?? 0)
        let text = (o["text"] as? String) ?? ""
        let e = o["error"] as? String
        return RawResult(status: st, text: text, error: e)
    }

    // MARK: Lấy token + dựng kênh API

    func readToken() async -> String? {
        if let t = await js(WebJS.docToken) as? String, !t.isEmpty { return t }
        return nil
    }

    func prepareChannel(stop: StopFlag, log: (String) -> Void) async throws -> ApiChannel {
        log("[API] Lấy token từ trang A1-Stream (WebView)...")
        load(Rules.targetURL)
        var token: String? = nil
        var loginHits = 0
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            try stop.check()
            try? await Task.sleep(nanoseconds: 400_000_000)
            let url = currentURL()
            if url.contains(Rules.loginDomain) {
                loginHits += 1
                if loginHits >= 6 {
                    throw AppError(message: "Chưa đăng nhập A1-Stream. Bấm nút Đăng nhập ở góc trên → đăng nhập (hoặc Tự đăng nhập) rồi chạy lại.")
                }
                continue
            }
            loginHits = 0
            if url.contains(Rules.appDomain), let t = await readToken() {
                token = t
                break
            }
        }
        guard let tok = token else {
            throw AppError(message: "Không lấy được token sau 40 giây. Mở màn hình Đăng nhập, kiểm tra trang đã vào được 'Dịch vụ / Job' chưa.")
        }
        let cookies: [HTTPCookie] = await withCheckedContinuation { (c: CheckedContinuation<[HTTPCookie], Never>) in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { c.resume(returning: $0) }
        }
        let relevant = cookies.filter { ck in
            let d = ck.domain.hasPrefix(".") ? String(ck.domain.dropFirst()) : ck.domain
            return Rules.appDomain == d || Rules.appDomain.hasSuffix("." + d)
        }
        let ua = (await js("navigator.userAgent") as? String) ?? ""

        let direct = DirectChannel(token: tok, cookies: relevant, userAgent: ua)
        if let j = try? await call(direct, Paths.userInfo, [:]), truthy(lay(j["data"], "userCode")) || truthy(j["data"]) {
            log("[API] Kênh gọi thẳng HTTP hoạt động (đã xác thực).")
            return direct
        }
        log("[API] Gọi thẳng HTTP chưa được -> dùng kênh qua trang web (WebView).")
        return WebChannel(token: tok)
    }

    // MARK: Tự đăng nhập (Cognito + TOTP)

    private func detectLoginPage() async -> LoginPage {
        guard let s = await js(WebJS.detect) as? String, let o = parseJSON(s) as? JSON else { return .none }
        guard let kind = o["loai"] as? String else { return .none }
        if kind == "login" { return .login(hasUser: (o["co_user"] as? Bool) ?? false) }
        if kind == "mfa" { return .mfa }
        return .none
    }

    private func fillField(_ k: String, _ value: String) async -> Bool {
        let (v, _) = await callJS(WebJS.fill, ["k": k, "t": value])
        return (v as? Bool) ?? false
    }

    private func clickSubmit(_ k: String) async -> Bool {
        let (v, _) = await callJS(WebJS.submit, ["k": k])
        return (v as? Bool) ?? false
    }

    func autoLogin(_ cfg: Credentials, stop: StopFlag, log: (String) -> Void) async throws {
        let end = Date().addingTimeInterval(90)
        var sentLoginAt: Date? = nil
        var sentMfaAt: Date? = nil
        var mfaCount = 0
        var lastCode: String? = nil
        var outsideSince: Date? = nil
        var reloaded = false

        let startURL = currentURL()
        if !(startURL.contains(Rules.appDomain) || startURL.contains(Rules.loginDomain)) {
            load(Rules.targetURL)
        }
        log("[Đăng nhập] Bắt đầu tự đăng nhập...")

        while Date() < end {
            try stop.check()
            let url = currentURL()
            let now = Date()

            if url.contains(Rules.loginDomain) {
                outsideSince = nil
                switch await detectLoginPage() {
                case .login(let hasUser):
                    if sentLoginAt == nil {
                        if !hasUser { throw AppError(message: "Không thấy ô Username trên trang đăng nhập.") }
                        let a = await fillField("user", cfg.username)
                        let b = await fillField("pass", cfg.password)
                        if a && b {
                            _ = await clickSubmit("pass")
                            sentLoginAt = now
                            log("[Đăng nhập] Đã nhập tài khoản + mật khẩu.")
                        }
                    } else if sentMfaAt == nil, let t = sentLoginAt, now.timeIntervalSince(t) > 12 {
                        throw AppError(message: "Gửi mật khẩu nhưng trang vẫn ở màn hình đăng nhập - kiểm tra lại tài khoản/mật khẩu.")
                    }
                case .mfa:
                    if sentMfaAt == nil || now.timeIntervalSince(sentMfaAt!) > 8 {
                        if mfaCount >= 3 { throw AppError(message: "Nhập mã TOTP 3 lần vẫn không qua - kiểm tra khoá TOTP.") }
                        if cfg.totpSecret.trimmed.isEmpty { throw AppError(message: "Trang đòi mã xác thực (MFA) nhưng chưa lưu khoá TOTP.") }
                        let code = try await TOTP.freshCode(secret: cfg.totpSecret, previous: lastCode, stop: stop)
                        if await fillField("code", code) {
                            _ = await clickSubmit("code")
                            sentMfaAt = Date()
                            lastCode = code
                            mfaCount += 1
                            log("[Đăng nhập] Đã nhập mã TOTP (lần \(mfaCount)).")
                        }
                    }
                case .none:
                    break
                }
            } else if url.contains(Rules.appDomain) {
                outsideSince = nil
                if await readToken() != nil {
                    log("[Đăng nhập] Đã đăng nhập xong.")
                    return
                }
            } else {
                if outsideSince == nil { outsideSince = now }
                if !reloaded, let t = outsideSince, now.timeIntervalSince(t) > 6 {
                    reloaded = true
                    load(Rules.targetURL)
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw AppError(message: "Quá 90 giây mà chưa đăng nhập xong. Mở màn hình Đăng nhập để xem trang đang ở đâu.")
    }
}

/// Hiển thị WebView dùng chung trong giao diện SwiftUI.
struct WebViewHost: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        return WebSession.shared.webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
