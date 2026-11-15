import Foundation

/// KIỂM TRA XE (CHỈ ĐỌC - không lưu, không tạo phiếu).
/// Luồng: getOrderDetail (phiếu trống) -> getMotorDetail -> [getPrivacyPolicyResult].
@MainActor
enum CheckFlow {

    static func verify(_ ch: ApiChannel, _ frame: String, stop: StopFlag) async throws -> CheckResult {
        var kq = CheckResult(frame: frame)
        try stop.check()
        let bodyXe = try await CommonFlow.buildVehicleBody(ch, frame)
        try stop.check()
        let mj = try await call(ch, Paths.motor, ["orderInfo": bodyXe])
        let moto = dataOf(mj)
        if !(truthy(moto["frameNo"]) && truthy(moto["modelCd"])) {
            kq.verdict = Verdict.notOK
            kq.reason = "Không tìm thấy thông tin xe theo số khung này"
            return kq
        }

        let words = Rules.nameWords(moto)
        kq.name = words.joined(separator: " ")
        kq.model = chuoi(moto["modelCd"])
        kq.soldDate = Rules.formatDate(chuoi(moto["soldDate"]))
        let sdt = chuoi(moto["mobilephone"])
        kq.phone = sdt

        var reasons: [String] = []
        var notes: [String] = []

        // 1) Số điện thoại
        var phoneForPolicy = ""
        if let why = Rules.checkPhone(sdt) {
            let last = (words.last ?? "").uppercased()
            if let newNo = Rules.replacementPhone(last), Rules.checkPhone(newNo) == nil {
                kq.phoneState = "Sai (tool tự đổi)"
                phoneForPolicy = newNo
                let hien = sdt.isEmpty ? "trống" : sdt
                notes.append("SĐT sai (\(hien)): \(why); tên khách '\(kq.name)' nên tool Nhập liệu sẽ tự đổi thành \(newNo)")
            } else {
                kq.phoneState = "Sai"
                let them = kq.name.isEmpty
                    ? " (không đọc được tên khách hàng)"
                    : " (tên khách hàng '\(kq.name)' không nằm trong danh sách được thay số)"
                reasons.append("SĐT sai: \(why)\(them)")
            }
        } else {
            kq.phoneState = "Đúng"
            phoneForPolicy = sdt
        }

        // 2) Chính sách quyền riêng tư
        var value: Any? = moto["policyResultFlag"]
        var agreed = Rules.policyAgreed(value)
        let changed = !phoneForPolicy.isEmpty && phoneForPolicy != sdt
        if !phoneForPolicy.isEmpty && (changed || !agreed) {
            try stop.check()
            var body = JSON()
            body["mobilePhone"] = phoneForPolicy
            body["firstNm"] = nv(moto["firstName"])
            body["middleNm"] = nv(moto["middleName"])
            body["lastNm"] = nv(moto["lastName"])
            do {
                let pj = try await call(ch, Paths.policy, body)
                let gt2 = lay(lay(pj, "data"), "agreementResult")
                if changed {
                    agreed = Rules.policyAgreed(gt2)
                    value = gt2
                    notes.append("Chính sách được tra theo SĐT thay thế")
                } else if Rules.policyAgreed(gt2) {
                    value = gt2
                    agreed = true
                }
            } catch let e as RunError {
                if case .api(let a) = e {
                    notes.append("Không tra cứu lại được chính sách: \(a.message)")
                    if changed {
                        value = nil
                        agreed = false
                    }
                } else {
                    throw e
                }
            }
        }
        kq.policy = agreed ? "Có" : "Chưa"
        kq.policyValue = rawString(value)
        if !agreed { reasons.append("Chưa có đồng ý chính sách quyền riêng tư") }

        kq.verdict = reasons.isEmpty ? Verdict.ok : Verdict.notOK
        reasons.append(contentsOf: notes)
        kq.reason = reasons.joined(separator: "; ")
        return kq
    }

    /// Lấy kênh API, tự lấy lại token 1 lần nếu hết hạn (HTTP 401/403).
    /// Trả (kết quả, dừng cả đợt). Chỉ .stopped mới thoát ra ngoài; lỗi khác -> "Lỗi tra cứu".
    static func one(_ session: ApiSession, _ frame: String, stop: StopFlag, log: (String) -> Void) async throws -> (CheckResult, Bool) {
        for attempt in 1...2 {
            guard let ch = try await session.getChannel(refresh: attempt == 2, stop: stop, log: log) else {
                return (CheckResult.failure(frame, "API: không lấy được token (đã đăng nhập A1-Stream chưa?) - đã dừng cả đợt"), true)
            }
            do {
                let kq = try await verify(ch, frame, stop: stop)
                return (kq, false)
            } catch let e as RunError {
                switch e {
                case .stopped:
                    throw e
                case .skip(let m), .hasResult(let m):
                    return (CheckResult.failure(frame, "Bỏ qua: \(m)"), false)
                case .api(let a), .notSaved(let a):
                    if attempt == 1, let c = a.httpCode, c == 401 || c == 403 {
                        log("  [Kiểm tra xe] Phiên/token hết hạn (HTTP \(c)) -> lấy lại token rồi thử lại xe \(frame).")
                        continue
                    }
                    return (CheckResult.failure(frame, "API: \(a.message)"), false)
                }
            }
        }
        return (CheckResult.failure(frame, "API: lỗi không xác định"), false)
    }
}
