import Foundation

/// SỬA CHỮA BẰNG API (TẠO PHIẾU THẬT). Luồng đúng như trang gọi:
/// initBaseData -> getOrderDetail (phiếu trống) -> getMotorDetail -> [đổi SĐT nếu DUY/THY]
/// -> serviceJobByModelList -> saveOrderInfo (LỆNH GHI DUY NHẤT) -> getOrderDetail -> getAppraisalTarget.
/// Lỗi TRƯỚC saveOrderInfo => chắc chắn chưa tạo phiếu. Lỗi SAU => "CÓ THỂ ĐÃ LƯU PHIẾU", không thử lại.
@MainActor
enum RepairFlow {
    static let label = "Sửa chữa-API"

    struct Prep {
        var tech: JSON
        var km: Int
        var price: Int
        var jobCode: String
        var moto: JSON
        var saveBody: JSON
        var newPhone: String?
    }

    static func prepare(
        _ ch: ApiChannel,
        _ cache: EmployeeCache,
        _ item: inout RepairItem,
        stop: StopFlag,
        log: (String) -> Void
    ) async throws -> Prep {
        let frame = item.frame
        let jobCode = item.jobCode.trimmed
        try stop.check()
        let staff = try await CommonFlow.loadEmployees(ch, cache)
        guard let tech = CommonFlow.findTech(staff, item.tech) else {
            throw apiErr("không thấy KTV '\(item.tech)' trong danh sách nhân viên")
        }
        let amountText = item.amount.trimmed
        if !Rules.allDigits(amountText) {
            throw apiErr("xe không có Số tiền hợp lệ (chế độ API chỉ làm khi có Giá bán đặc biệt)")
        }
        guard let price = Int(amountText) else { throw apiErr("Số tiền '\(amountText)' quá lớn") }

        try stop.check()
        var moto = try await CommonFlow.fetchVehicle(ch, frame, required: ["frameNo", "modelCd", "cmmSerializedProductId"])

        // SĐT sai -> DUY/THY đổi số, tên khác bỏ qua xe
        let newPhone = try await CommonFlow.fixPhoneIfWrong(ch, &moto, &item.note, kind: .repair, label: label, log: log)

        // Công việc
        try stop.check()
        var jb = JSON()
        jb["content"] = jobCode
        jb["modelCode"] = nv(moto["modelCd"])
        jb["pageSize"] = 10
        jb["currentPage"] = 1
        let cv = try await call(ch, Paths.jobs, jb)
        let jobs = listOf(lay(lay(cv, "data"), "list")).compactMap { $0 as? JSON }
        guard let job = jobs.first(where: { chuoi($0["code"]).uppercased() == jobCode.uppercased() }) else {
            throw apiErr("không thấy mã công việc '\(jobCode)' cho model \(pyStr(moto["modelCd"]))")
        }

        // Dựng lệnh lưu
        let km = Int.random(in: Rules.kmRepairMin...Rules.kmRepairMax)
        let start = CommonFlow.startTime(moto)
        let finish = CommonFlow.plus(start, minutes: Rules.repairExtraMinutes)
        var don = moto
        don["mileage"] = km
        try CommonFlow.fillTech(&don, tech)
        don["operationStart"] = CommonFlow.fmt(start)
        don["operationFinish"] = CommonFlow.fmt(finish)
        don["finalAmt"] = price
        don["sumOrderAmt"] = price
        don["dbPolicyResult"] = nv(moto["policyResultFlag"])
        don["stuDate"] = nv(moto["soldDate"])
        don["dbModelTypeId"] = nv(moto["modelTypeId"])
        don["newVoucherFlag"] = false
        don["appraisalTargetInput"] = NSNull()
        if var vl = don["voucherList"] as? [Any], let first = vl.first as? JSON {
            var f = first
            f["_ROW_KEY_"] = "row_\(Int.random(in: 50...99))"
            vl[0] = f
            don["voucherList"] = vl
        }

        var dong = JSON()
        dong["serviceCategoryId"] = "S012REPAIR"
        dong["serviceDemandContent"] = NSNull()
        dong["serviceDemandId"] = NSNull()
        dong["settleTypeId"] = "S013CUSTOMER"
        dong["manhour"] = pyStr(job["manHours"])
        dong["standardPrice"] = nv(job["stdRetailPrice"])
        dong["sellingPrice"] = price
        dong["symptomId"] = NSNull()
        dong["jobCd"] = nv(job["code"])
        dong["jobNm"] = nv(job["name"])
        dong["discountAmt"] = NSNull()
        dong["discount"] = NSNull()
        dong["specialPrice"] = price
        dong["servicePackageNm"] = NSNull()
        dong["_ROW_KEY_"] = "row_\(Int.random(in: 50...99))"
        dong["jobId"] = pyStr(job["id"])
        dong["taxRate"] = nv(job["vatRate"])

        var jobList = CommonFlow.emptyPack()
        jobList["insertRecords"] = [dong]
        var body = JSON()
        body["orderInfo"] = don
        body["situationList"] = CommonFlow.emptyPack()
        body["jobList"] = jobList
        body["partList"] = CommonFlow.emptyPack()
        body["batteryList"] = [Any]()
        body["partDetailList"] = [Any]()
        try stop.check()
        return Prep(tech: tech, km: km, price: price, jobCode: jobCode, moto: moto, saveBody: body, newPhone: newPhone)
    }

    /// Sửa chữa 1 xe. Trả Số Đơn hàng.
    /// Lỗi .notSaved/.skip/.stopped = chưa tạo phiếu; .api = lỗi SAU lệnh lưu (có thể đã tạo phiếu).
    static func create(
        _ ch: ApiChannel,
        _ cache: EmployeeCache,
        _ item: inout RepairItem,
        stop: StopFlag,
        log: (String) -> Void
    ) async throws -> String {
        let cb: Prep
        do {
            cb = try await prepare(ch, cache, &item, stop: stop, log: log)
        } catch {
            throw toNotSaved(error)
        }

        // ===== TỪ ĐÂY: lệnh LƯU. Không quay lại / không thử lại nếu lỗi (tránh tạo phiếu trùng). =====
        log("  [\(label)] Xe \(item.frame): lưu phiếu (KTV \(pyStr(cb.tech["code"])), Km \(cb.km), CV \(cb.jobCode), giá \(cb.price))...")
        let saved = try await call(ch, Paths.save, cb.saveBody)
        let code = saved["data"]
        if !truthy(code) { throw apiErr("saveOrderInfo không trả về mã phiếu (serviceOrderId)") }
        let detail = try await CommonFlow.reloadOrder(ch, cb.moto, code, item.frame)
        let orderNo = chuoi(detail["orderNo"])
        if orderNo.isEmpty {
            throw apiErr("đã lưu phiếu (serviceOrderId=\(pyStr(code))) nhưng không đọc được Số Đơn hàng - KIỂM TRA TAY trên A1-Stream")
        }
        if let sdt = cb.newPhone {
            let hien = chuoi(detail["mobilephone"])
            if hien != sdt {
                let canhBao = "CẢNH BÁO: đã gửi đổi SĐT thành \(sdt) nhưng sau khi lưu phiếu hiển thị '\(pyStr(detail["mobilephone"]))' - kiểm tra tay"
                log("  [\(label)] \(canhBao)")
                CommonFlow.addNote(&item.note, canhBao)
            }
        }
        await CommonFlow.callYas(ch, code: code, moto: cb.moto, frame: item.frame, km: cb.km, label: label, log: log)
        log("  Số Đơn hàng vừa tạo (API): \(orderNo)")
        return orderNo
    }

    /// Làm 1 xe với kênh của đợt (lấy lại token 1 lần nếu hết hạn).
    /// Bất kỳ sai sót nào -> bỏ qua xe, ghi lý do. Chỉ "Dừng ngay" mới thoát ra ngoài bằng throw.
    static func one(
        _ session: ApiSession,
        _ cache: EmployeeCache,
        _ item: inout RepairItem,
        stop: StopFlag,
        log: (String) -> Void,
        status: (String) -> Void
    ) async throws -> StepResult {
        for attempt in 1...2 {
            guard let ch = try await session.getChannel(refresh: attempt == 2, stop: stop, log: log) else {
                return StepResult(
                    result: ItemResult.failed("API: không lấy được token (đã đăng nhập A1-Stream chưa?) - đã dừng cả đợt"),
                    stopAll: true
                )
            }
            item.note = ""
            status("Xe \(item.frame): đang nhập liệu bằng API...")
            var res: ItemResult
            do {
                let orderNo = try await create(ch, cache, &item, stop: stop, log: log)
                res = ItemResult.success(orderNo, item.note)
            } catch let e as RunError {
                switch e {
                case .stopped:
                    throw e
                case .notSaved(let a):
                    if attempt == 1, let c = a.httpCode, c == 401 || c == 403 {
                        log("  [API] Phiên/token hết hạn (HTTP \(c)) -> lấy lại token rồi thử lại xe \(item.frame).")
                        continue
                    }
                    res = ItemResult.failed("API (chưa lưu phiếu): \(a.message)")
                case .skip(let m):
                    res = ItemResult.skipped(m)
                case .hasResult(let m):
                    res = ItemResult.skipped(m)
                case .api(let a):
                    res = ItemResult.failed("API (CÓ THỂ ĐÃ LƯU PHIẾU, kiểm tra tay trước khi chạy lại): \(a.message)")
                }
            } catch {
                res = ItemResult.failed("Lỗi không lường trước (CÓ THỂ ĐÃ LƯU PHIẾU, kiểm tra tay trước khi chạy lại): \(errText(error))")
            }
            return StepResult(result: res, stopAll: false)
        }
        return StepResult(result: ItemResult.failed("API: lỗi không xác định"), stopAll: false)
    }
}
