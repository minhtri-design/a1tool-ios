import Foundation

/// KẾT THÚC BT / DV BẰNG API. Chuỗi lệnh của trang:
/// getOrderDetail(orderNo) -> getPrivacyPolicyResult -> settleOrder (LỆNH GHI DUY NHẤT) -> getAppraisalTarget -> getOrderDetail.
/// Trạng thái phiếu: S032WAITFORSETTLE (60. Wait for settle) -> S032COMPLETED (ZZ. Completed).
@MainActor
enum SettleFlow {
    static let label = "KT-API"

    /// Dựng body settleOrder từ dữ liệu getOrderDetail.
    static func buildBody(_ detail: JSON) -> JSON {
        var oi: JSON = (normalizeNumbers(detail) as? JSON) ?? detail
        var tong: Any = 0
        if let ds = oi["summaryList"] as? [Any] {
            for dong in ds {
                if chuoiTho(lay(dong, "settleTypeId")) == "S013CUSTOMER" {
                    if let p = lay(dong, "payableAmt"), truthy(p) {
                        tong = p
                    } else if let t = lay(dong, "total"), truthy(t) {
                        tong = t
                    } else {
                        tong = 0
                    }
                    break
                }
            }
        }
        let modelType = nv(oi["modelTypeId"])
        let policy = nv(oi["policyResultFlag"])
        let sold = nv(oi["soldDate"])
        oi["appraisalTargetInput"] = NSNull()
        oi["dbModelTypeId"] = modelType
        oi["dbPolicyResult"] = policy
        oi["demandType"] = "DEMAND"
        oi["newVoucherFlag"] = false
        oi["orderId"] = NSNull()
        oi["stuDate"] = sold
        oi["finalAmt"] = tong
        oi["sumOrderAmt"] = tong
        if let vl = oi["voucherList"] as? [Any] {
            var moi: [Any] = []
            for v in vl {
                if var vo = v as? JSON {
                    if vo["_ROW_KEY_"] == nil { vo["_ROW_KEY_"] = "row_109" }
                    moi.append(vo)
                } else {
                    moi.append(v)
                }
            }
            oi["voucherList"] = moi
        }
        var chiTietPt: [Any] = []
        if let pl = oi["partList"] as? [Any] {
            for (i, pt) in pl.enumerated() {
                if var p = pt as? JSON {
                    p["_ROW_KEY_"] = "row_\(96 + i)"
                    p["ymvnStock"] = ""
                    chiTietPt.append(p)
                } else {
                    chiTietPt.append(pt)
                }
            }
        }
        var body = JSON()
        body["orderInfo"] = oi
        body["situationList"] = CommonFlow.emptyPack()
        body["jobList"] = CommonFlow.emptyPack()
        body["partList"] = CommonFlow.emptyPack()
        body["batteryList"] = [Any]()
        body["partDetailList"] = chiTietPt
        return body
    }

    enum Prep {
        /// Đã hoàn tất từ trước, không cần kết thúc nữa.
        case alreadyDone
        case ready(JSON, JSON)
    }

    static func prepare(_ ch: ApiChannel, _ orderNo: String, stop: StopFlag, log: (String) -> Void) async throws -> Prep {
        try stop.check()
        let blank: JSON = ["orderInfo": ["pointId": "", "orderNo": "", "frameNo": "", "plateNo": ""]]
        let mau = dataOf(try await call(ch, Paths.order, blank))
        if !truthy(mau["pointId"]) { throw apiErr("getOrderDetail (phiếu trống) không trả pointId") }

        try stop.check()
        var q = JSON()
        q["pointId"] = nv(mau["pointId"])
        q["orderNo"] = orderNo
        q["serviceOrderId"] = NSNull()
        q["frameNo"] = NSNull()
        q["plateNo"] = NSNull()
        var ct = dataOf(try await call(ch, Paths.order, ["orderInfo": q]))
        if chuoiTho(ct["orderNo"]) != orderNo || !truthy(ct["serviceOrderId"]) {
            throw apiErr("không tìm thấy đơn hàng \(orderNo)")
        }
        let tt = (ct["orderStatusId"] as? String) ?? ""
        if tt == "S032COMPLETED" {
            log("  [\(label)] \(orderNo) đã Hoàn tất từ trước -> coi như xong.")
            return .alreadyDone
        }
        if tt != "S032WAITFORSETTLE" {
            throw apiErr("đơn đang ở trạng thái '\(pyStr(ct["orderStatus"]))' (\(tt.isEmpty ? "None" : tt)), không phải 'Wait for settle' -> không kết thúc")
        }
        // Trang tra chính sách riêng tư rồi gán vào policyResultFlag (lỗi: dùng giá trị sẵn có).
        var pb = JSON()
        pb["mobilePhone"] = nv(ct["mobilephone"])
        pb["firstNm"] = nv(ct["firstName"])
        pb["middleNm"] = nv(ct["middleName"])
        pb["lastNm"] = nv(ct["lastName"])
        do {
            let pj = try await call(ch, Paths.policy, pb)
            if let kq = lay(lay(pj, "data"), "agreementResult"), truthy(kq) {
                ct["policyResultFlag"] = kq
            }
        } catch {
            log("  [\(label)] getPrivacyPolicyResult lỗi (dùng giá trị sẵn có): \(errText(error))")
        }
        // Server từ chối nếu giờ hiện tại < giờ hoàn tất dự kiến -> kiểm tra trước, khỏi gửi lệnh vô ích.
        let hienTai = String(chuoiTho(mau["startTime"]).prefix(12))
        let xongDuKien = String(chuoiTho(ct["operationFinish"]).prefix(12))
        if hienTai.count == 12 && xongDuKien.count == 12 && hienTai < xongDuKien {
            func gio(_ s: String) -> String {
                return "\(s.dropFirst(8).prefix(2)):\(s.dropFirst(10).prefix(2))"
            }
            throw apiErr("CHƯA ĐẾN GIỜ kết thúc: giờ hoàn tất dự kiến \(gio(xongDuKien)) (hiện tại \(gio(hienTai))) - chạy lại sau giờ này")
        }
        return .ready(ct, buildBody(ct))
    }

    /// Kết thúc 1 Số Đơn hàng. Trả ghi chú ("" nếu bình thường).
    /// .notSaved/.stopped = chắc chắn chưa kết thúc; .api = lỗi SAU settleOrder (CÓ THỂ ĐÃ kết thúc).
    static func settle(_ ch: ApiChannel, _ orderNo: String, stop: StopFlag, log: (String) -> Void) async throws -> String {
        let prep: Prep
        do {
            prep = try await prepare(ch, orderNo, stop: stop, log: log)
        } catch {
            throw toNotSaved(error)
        }
        let ct: JSON
        let body: JSON
        switch prep {
        case .alreadyDone:
            return "Đơn đã hoàn tất từ trước"
        case .ready(let c, let b):
            ct = c
            body = b
        }

        // ---- LỆNH GHI DUY NHẤT: sau dòng này KHÔNG được thử lại ----
        try stop.check()
        do {
            _ = try await call(ch, Paths.settle, body)
        } catch let e as RunError {
            if case .api(let a) = e, let ma = a.httpCode, (400..<500).contains(ma), ma != 401, ma != 403 {
                // Server từ chối vì sai nghiệp vụ (HTTP 4xx) -> chắc chắn CHƯA kết thúc. Lấy lý do gốc của server.
                var lyDo = ""
                if let raw = a.raw, let j = parseJSON(raw) as? JSON {
                    lyDo = chuoiTho(j["reason"])
                }
                let noiDung = lyDo.isEmpty ? a.message : lyDo
                throw RunError.notSaved(ApiError(message: "server từ chối settleOrder: \(noiDung)"))
            }
            throw e
        }

        // Trang gọi kiểm tra YAS sau khi kết thúc -> gọi cho giống, lỗi bỏ qua.
        var yas = JSON()
        yas["serviceOrderId"] = nv(ct["serviceOrderId"])
        yas["siteId"] = nv(ct["pointCd"])
        yas["orderNo"] = NSNull()
        yas["frameNo"] = nv(ct["frameNo"])
        yas["plateNo"] = nv(ct["plateNo"])
        yas["soldDate"] = nv(ct["soldDate"])
        yas["mileage"] = nv(ct["mileage"])
        yas["modelCd"] = nv(ct["modelCd"])
        yas["userId"] = "A1Stream"
        do {
            _ = try await call(ch, Paths.yas, yas)
        } catch {
            log("  [\(label)] getAppraisalTarget lỗi (bỏ qua): \(errText(error))")
        }
        var oi = JSON()
        oi["pointId"] = nv(ct["pointId"])
        oi["orderNo"] = NSNull()
        oi["serviceOrderId"] = nv(ct["serviceOrderId"])
        oi["frameNo"] = nv(ct["frameNo"])
        oi["plateNo"] = nv(ct["plateNo"])
        let xacNhan = dataOf(try await call(ch, Paths.order, ["orderInfo": oi]))
        if (xacNhan["orderStatusId"] as? String) != "S032COMPLETED" {
            throw apiErr("đã gửi settleOrder nhưng trạng thái đơn là '\(pyStr(xacNhan["orderStatus"]))' (chưa Completed)")
        }
        return ""
    }

    /// Làm 1 đơn hàng. Lỗi gì cũng BỎ QUA đơn đó, ghi lý do. Chỉ "Dừng ngay" mới thoát bằng throw.
    static func one(
        _ session: ApiSession,
        _ orderNo: String,
        stop: StopFlag,
        log: (String) -> Void,
        status: (String) -> Void
    ) async throws -> StepResult {
        guard let ch = try await session.getChannel(refresh: false, stop: stop, log: log) else {
            return StepResult(
                result: ItemResult.failed("API: không lấy được token (đã đăng nhập A1-Stream chưa?)"),
                stopAll: false
            )
        }
        status("Đơn hàng \(orderNo): đang kết thúc bằng API...")
        let res: ItemResult
        do {
            let note = try await settle(ch, orderNo, stop: stop, log: log)
            if !note.isEmpty { status("Đơn hàng \(orderNo): \(note)") }
            res = ItemResult.success("", "")
        } catch let e as RunError {
            switch e {
            case .stopped:
                throw e
            case .notSaved(let a):
                if let c = a.httpCode, c == 401 || c == 403 {
                    log("  [API] Phiên/token hết hạn (HTTP \(c)) -> bỏ đơn \(orderNo), đơn sau sẽ lấy token mới.")
                    await session.close()
                }
                res = ItemResult.failed("API (chưa kết thúc): \(a.message)")
            case .skip(let m):
                res = ItemResult.skipped(m)
            case .hasResult(let m):
                res = ItemResult.skipped(m)
            case .api(let a):
                res = ItemResult.failed("API (CÓ THỂ ĐÃ KẾT THÚC, kiểm tra tay trước khi chạy lại): \(a.message)")
            }
        } catch {
            res = ItemResult.failed("Lỗi không lường trước (CÓ THỂ ĐÃ KẾT THÚC, kiểm tra tay trước khi chạy lại): \(errText(error))")
        }
        return StepResult(result: res, stopAll: false)
    }
}
