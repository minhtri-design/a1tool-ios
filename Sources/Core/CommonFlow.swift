import Foundation

/// Danh sách nhân viên (KTV) lấy từ initBaseData, giữ 10 phút.
final class EmployeeCache {
    var at: Date?
    var list: [JSON] = []
}

/// Phần dùng chung của các chế độ.
@MainActor
enum CommonFlow {

    // MARK: Gói thay đổi rỗng

    static func emptyPack() -> JSON {
        var p = JSON()
        p["insertRecords"] = [Any]()
        p["removeRecords"] = [Any]()
        p["updateRecords"] = [Any]()
        p["pendingRecords"] = [Any]()
        return p
    }

    // MARK: Nhân viên

    static func loadEmployees(_ ch: ApiChannel, _ cache: EmployeeCache) async throws -> [JSON] {
        if let t = cache.at, !cache.list.isEmpty, Date().timeIntervalSince(t) < 600 {
            return cache.list
        }
        let j = try await call(ch, Paths.employees)
        let txt = chuoiTho(lay(lay(j, "data"), "EMPLOYEE"))
        let src = txt.isEmpty ? "[]" : txt
        guard let arr = parseJSON(src) as? [Any] else {
            throw apiErr("initBaseData: danh sách nhân viên không đọc được")
        }
        let ds = arr.compactMap { $0 as? JSON }
        if ds.isEmpty { throw apiErr("initBaseData không có danh sách nhân viên (EMPLOYEE)") }
        cache.at = Date()
        cache.list = ds
        return ds
    }

    /// Tìm KTV theo mã (code) trước, rồi theo tên (desc / name); không phân biệt hoa/thường.
    static func findTech(_ list: [JSON], _ ktv: String) -> JSON? {
        let k = ktv.trimmed.uppercased()
        if k.isEmpty { return nil }
        func up(_ e: JSON, _ key: String) -> String {
            return pyStrIfPresent(e[key]).trimmed.uppercased()
        }
        if let theoMa = list.first(where: { up($0, "code") == k }) { return theoMa }
        return list.first(where: { up($0, "desc") == k || up($0, "name") == k })
    }

    static func techId(_ k: JSON) throws -> Int {
        guard let v = k["id"] else { throw apiErr("KTV không có id") }
        if !isBoolValue(v), let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s.trimmed) { return i }
        throw apiErr("id của KTV không phải số: \(pyStr(v))")
    }

    static func fillTech(_ don: inout JSON, _ ktv: JSON) throws {
        let id = try techId(ktv)
        guard let code = ktv["code"] else { throw apiErr("KTV không có code") }
        don["mechanicId"] = id
        don["mechanicCd"] = code
        don["mechanicNm"] = pyStrIfPresent(ktv["name"]).uppercased()
    }

    // MARK: Giờ server (giờ "naive", không đổi múi giờ)

    private static let fmtMinute: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmm"
        return f
    }()

    private static let fmtDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    /// Giờ bắt đầu = startTime server trả (yyyymmddHHMM); lỗi thì dùng giờ máy.
    static func startTime(_ data: Any?) -> Date {
        if let d = fmtMinute.date(from: pyStrIfPresent(lay(data, "startTime"))) { return d }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone.current
        local.dateFormat = "yyyyMMddHHmm"
        return fmtMinute.date(from: local.string(from: Date())) ?? Date()
    }

    static func fmt(_ d: Date) -> String { return fmtMinute.string(from: d) }
    static func fmtDayOnly(_ d: Date) -> String { return fmtDay.string(from: d) }
    static func plus(_ d: Date, minutes: Int) -> Date { return d.addingTimeInterval(Double(minutes) * 60.0) }

    // MARK: Ghi chú

    static func addNote(_ note: inout String, _ more: String) {
        if more.isEmpty { return }
        if note.isEmpty { note = more } else { note += "; " + more }
    }

    // MARK: Xe

    /// Body "xe" dùng chung cho getMotorDetail: lấy phiếu trống rồi điền số khung.
    static func buildVehicleBody(_ ch: ApiChannel, _ frame: String) async throws -> JSON {
        let blank: JSON = ["orderInfo": ["pointId": "", "orderNo": "", "frameNo": "", "plateNo": ""]]
        let j = try await call(ch, Paths.order, blank)
        var body = dataOf(j)
        if !truthy(body["pointId"]) { throw apiErr("getOrderDetail (phiếu trống) không trả pointId") }
        body["frameNo"] = frame
        body["plateNo"] = ""
        body["serviceCategoryId"] = "S012REPAIR"
        body["appraisalTargetInput"] = NSNull()
        body["dbPolicyResult"] = NSNull()
        body["newVoucherFlag"] = false
        body["finalAmt"] = 0
        body["sumOrderAmt"] = 0
        return body
    }

    /// Số khung -> getMotorDetail -> dữ liệu xe (phải có đủ các khoá bắt buộc).
    static func fetchVehicle(_ ch: ApiChannel, _ frame: String, required: [String]) async throws -> JSON {
        let bodyXe = try await buildVehicleBody(ch, frame)
        let j = try await call(ch, Paths.motor, ["orderInfo": bodyXe])
        let moto = dataOf(j)
        for k in required where !truthy(moto[k]) {
            throw apiErr("getMotorDetail không trả đủ thông tin xe cho số khung \(frame)")
        }
        return moto
    }

    /// Sau lệnh lưu: đọc lại phiếu theo serviceOrderId.
    static func reloadOrder(_ ch: ApiChannel, _ moto: JSON, _ code: Any?, _ frame: String) async throws -> JSON {
        var oi = JSON()
        oi["pointId"] = nv(moto["pointId"])
        oi["orderNo"] = NSNull()
        oi["serviceOrderId"] = nv(code)
        oi["frameNo"] = frame
        oi["plateNo"] = nv(moto["plateNo"])
        let j = try await call(ch, Paths.order, ["orderInfo": oi])
        return dataOf(j)
    }

    /// Trang vẫn gọi sau khi lưu (kiểm tra YAS) -> gọi cho giống, lỗi bỏ qua.
    static func callYas(_ ch: ApiChannel, code: Any?, moto: JSON, frame: String, km: Int, label: String, log: (String) -> Void) async {
        var b = JSON()
        b["serviceOrderId"] = nv(code)
        b["siteId"] = nv(moto["pointCd"])
        b["orderNo"] = NSNull()
        b["frameNo"] = frame
        b["plateNo"] = nv(moto["plateNo"])
        b["soldDate"] = nv(moto["soldDate"])
        b["mileage"] = km
        b["modelCd"] = nv(moto["modelCd"])
        b["userId"] = "A1Stream"
        do {
            _ = try await call(ch, Paths.yas, b)
        } catch {
            log("  [\(label)] getAppraisalTarget lỗi (bỏ qua): \(errText(error))")
        }
    }

    // MARK: SĐT sai -> đổi theo tên (DUY / THY), tên khác -> bỏ qua xe

    enum PhoneFixKind {
        /// Sửa chữa: chỉ ghi đè policyResultFlag khi tra cứu có kết quả.
        case repair
        /// Nhập liệu BT: gán thẳng kết quả tra cứu (kể cả null) và thêm fullNm.
        case maintenance
    }

    /// SĐT hợp lệ -> nil. Sai + tên DUY/THY -> sửa thẳng vào `moto`, trả số mới. Sai + tên khác -> throw .skip.
    static func fixPhoneIfWrong(
        _ ch: ApiChannel,
        _ moto: inout JSON,
        _ note: inout String,
        kind: PhoneFixKind,
        label: String,
        log: (String) -> Void
    ) async throws -> String? {
        let sdt = chuoi(moto["mobilephone"])
        guard let why = Rules.checkPhone(sdt) else { return nil }
        let words = Rules.nameWords(moto)
        let full = words.joined(separator: " ")
        let last = (words.last ?? "").uppercased()
        log("  [\(label)] SĐT sai (\(why)). Tên khách hàng: '\(full)'.")
        guard let newNo = Rules.replacementPhone(last) else {
            let them = full.isEmpty
                ? " (không đọc được tên khách hàng)"
                : " (tên khách hàng '\(full)' không nằm trong danh sách được thay số)"
            throw RunError.skip(why + them)
        }
        if Rules.checkPhone(newNo) != nil {
            throw RunError.skip("Số thay thế cho tên \(last) không hợp lệ")
        }
        moto["mobilephone"] = newNo
        var body = JSON()
        body["mobilePhone"] = newNo
        body["firstNm"] = nv(moto["firstName"])
        body["middleNm"] = nv(moto["middleName"])
        body["lastNm"] = nv(moto["lastName"])
        do {
            let pj = try await call(ch, Paths.policy, body)
            let kq = lay(lay(pj, "data"), "agreementResult")
            switch kind {
            case .repair:
                if let k = kq, truthy(k) { moto["policyResultFlag"] = k }
            case .maintenance:
                moto["policyResultFlag"] = nv(kq)
                moto["fullNm"] = nv(moto["middleName"])
            }
        } catch {
            log("  [\(label)] Tra cứu chính sách sau đổi SĐT lỗi (bỏ qua): \(errText(error))")
        }
        let ghi = "SĐT sai (\(sdt.isEmpty ? "trống" : sdt)), đã đổi thành \(newNo) theo tên \(last)"
        log("  [\(label)] \(ghi)")
        addNote(&note, ghi)
        return newNo
    }

    // MARK: Giãn cách giữa các phiếu

    /// Chờ cho đủ `seconds` kể từ lúc xong phiếu trước (`since` = nil: không chờ). Bấm Dừng là thoát ngay.
    static func waitGap(seconds: Double, since: Date?, stop: StopFlag, label: String, say: (String) -> Void) async throws {
        guard let since = since, seconds > 0 else { return }
        let end = since.addingTimeInterval(seconds)
        let con = end.timeIntervalSinceNow
        if con > 0.5 { say("\(label): chờ \(Int(con.rounded()))s giãn cách giữa các phiếu...") }
        while true {
            try stop.check()
            let r = end.timeIntervalSinceNow
            if r <= 0 { return }
            let ns = UInt64(min(r, 0.5) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
        }
    }
}
