import Foundation

enum Paths {
    static let employees = "/service/svm0102/initBaseData.json"
    static let order = "/service/svm0102/getOrderDetail.json"
    static let motor = "/service/svm0102/getMotorDetail.json"
    static let policy = "/common/codevalue/getPrivacyPolicyResult.json"
    static let save = "/service/svm0102/saveOrderInfo.json"
    static let yas = "/oauth2-api/a1stream/yas/getAppraisalTarget.json"
    static let settle = "/service/svm0102/settleOrder.json"
    static let jobs = "/common/valuelist/serviceJobByModelList.json"
    static let demand = "/common/valuelist/demandList.json"
    static let couponHistory = "/service/svm0102/getFreeCouponHistory.json"
    static let couponDetail = "/service/svm0102/getFreeCouponDetail.json"
    static let parts = "/common/valuelist/partsList.json"
    static let stock = "/common/codevalue/getYmvnStock.json"
    static let userInfo = "/user/info"
}

/// Phản hồi thô của 1 lệnh gọi.
struct RawResult {
    var status: Int
    var text: String
    var error: String?
}

protocol ApiChannel: AnyObject {
    func post(_ path: String, body: JSON?) async -> RawResult
    func close() async
}

extension ApiChannel {
    func close() async {}
}

/// POST tới API, trả JSON đã kiểm tra (HTTP 200, là object, server không báo lỗi nghiệp vụ).
func call(_ ch: ApiChannel, _ path: String, _ body: JSON? = nil) async throws -> JSON {
    let r = await ch.post(path, body: body)
    func cut(_ s: String) -> String { return String(s.prefix(200)) }

    if r.status != 200 {
        let why = r.error ?? cut(r.text)
        throw RunError.api(ApiError(message: "\(path): HTTP \(r.status) \(why)", httpCode: r.status, raw: r.text))
    }
    guard let obj = parseJSON(r.text) else {
        throw RunError.api(ApiError(message: "\(path): trả về không phải JSON: \(cut(r.text))", httpCode: nil, raw: r.text))
    }
    guard let j = obj as? JSON else {
        throw RunError.api(ApiError(message: "\(path): JSON không đúng dạng object", httpCode: nil, raw: r.text))
    }
    var statusOK = true
    if let s = j["status"], !(s is NSNull) {
        statusOK = (soThuc(s) == 200.0)
    }
    let severityError = (j["severityLevel"] as? String)?.lowercased() == "error"
    if !statusOK || severityError {
        var msg = ""
        if let ms = j["messages"] as? [Any] {
            msg = ms.compactMap { $0 as? JSON }.map { ($0["message"] as? String) ?? "" }.joined(separator: "; ")
        }
        let code: Int? = soThuc(j["status"]).flatMap { $0.isFinite ? Int($0) : nil }
        let content = msg.isEmpty ? cut(jsonString(j)) : msg
        throw RunError.api(ApiError(message: "\(path): server báo lỗi: \(content)", httpCode: code, raw: r.text))
    }
    return j
}

// MARK: - Kênh 1: gọi thẳng bằng HTTP (token + cookie lấy từ trang đã đăng nhập)

final class DirectChannel: ApiChannel {
    private let token: String
    private let cookie: String
    private let userAgent: String
    private let session: URLSession

    init(token: String, cookies: [HTTPCookie], userAgent: String) {
        self.token = token
        self.cookie = cookies.filter { !$0.name.isEmpty }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        self.userAgent = userAgent.isEmpty ? "Mozilla/5.0" : userAgent
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 40
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
    }

    func post(_ path: String, body: JSON?) async -> RawResult {
        guard let url = URL(string: "https://\(Rules.appDomain)\(Rules.apiRoot)\(path)") else {
            return RawResult(status: 0, text: "", error: "URL sai: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("vn", forHTTPHeaderField: "Accept-Language")
        req.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://\(Rules.appDomain)", forHTTPHeaderField: "Origin")
        req.setValue(Rules.targetURL, forHTTPHeaderField: "Referer")
        if !cookie.isEmpty { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let b = body, let d = toJSONData(b) {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = d
        } else {
            req.httpBody = Data()
        }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return RawResult(status: code, text: String(data: data, encoding: .utf8) ?? "", error: nil)
        } catch {
            return RawResult(status: 0, text: "", error: error.localizedDescription)
        }
    }
}

// MARK: - Kênh 2: fetch ngay trong trang web đã đăng nhập (dự phòng khi server từ chối gọi thẳng)

final class WebChannel: ApiChannel {
    private let token: String

    init(token: String) {
        self.token = token
    }

    func post(_ path: String, body: JSON?) async -> RawResult {
        return await WebSession.shared.fetch(path: path, body: body, token: token)
    }
}
