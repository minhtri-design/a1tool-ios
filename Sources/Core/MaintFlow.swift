import Foundation

/// NHẬP LIỆU BẢO TRÌ BẰNG API (TẠO PHIẾU THẬT). Luồng (đúng thứ tự trang gọi):
/// getOrderDetail (phiếu trống) -> getMotorDetail -> [đổi SĐT nếu DUY/THY] -> demandList (9 phiếu BT của xe)
/// -> getFreeCouponHistory (phiếu nào đã dùng) -> getFreeCouponDetail (mã công việc -> jobId/thuế)
/// -> [có Phụ tùng] partsList + getYmvnStock -> saveOrderInfo (LỆNH GHI DUY NHẤT) -> getOrderDetail -> getAppraisalTarget.
/// Quy tắc: Km random theo số phiếu; phút kết thúc + giá đặc biệt theo số phiếu; phiếu đã có kết quả Y/N -> bỏ qua;
/// còn phiếu nhỏ hơn chưa dùng -> bỏ qua để kiểm tra tay; tồn kho <= Số lượng dừng -> không thêm phụ tùng.
@MainActor
enum MaintFlow {
    static let label = "BT-API"

    /// Xác định xe đang tới hạn PHIẾU SỐ MẤY (khoảng [fromDate, toDate] chứa hôm nay) và đối chiếu lịch sử dùng phiếu.
    static func pickTicket(_ ch: ApiChannel, _ moto: JSON, today: String) async throws -> (Int, JSON) {
        var b = JSON()
        b["arg0"] = "S012FREECOUPON"
        b["arg1"] = nv(moto["cmmSerializedProductId"])
        b["arg2"] = nv(moto["soldDate"])
        let dl = try await call(ch, Paths.demand, b)
        let ds = listOf(lay(lay(dl, "data"), "list"))
            .compactMap { $0 as? JSON }
            .filter { Rules.allDigits(chuoiTho($0["serviceDemandId"])) }
        if ds.isEmpty { throw apiErr("demandList không trả về phiếu BT nào cho xe này") }
        let hop = ds.filter { chuoiTho($0["fromDate"]) <= today && today <= chuoiTho($0["toDate"]) }
        guard let phieu = hop.first else {
            throw RunError.skip("Hôm nay (\(today)) không nằm trong khoảng hạn của phiếu BT nào - bỏ qua")
        }
        guard let soPhieu = Int(chuoiTho(phieu["serviceDemandId"])) else {
            throw apiErr("serviceDemandId không phải số")
        }

        var oi = JSON()
        oi["cmmSerializedProductId"] = nv(moto["cmmSerializedProductId"])
        oi["modelCd"] = nv(moto["modelCd"])
        oi["soldDate"] = nv(moto["soldDate"])
        let ls = try await call(ch, Paths.couponHistory, ["orderInfo": oi])
        let kqLs = listOf(lay(lay(ls, "data"), "freeCouponResult")).compactMap { $0 as? JSON }
        // Kết quả của phiếu số k (vị trí k-1 trong danh sách).
        func ketQua(_ k: Int) -> String {
            if k > 0 && k <= kqLs.count { return chuoi(kqLs[k - 1]["couponResult"]).uppercased() }
            return ""
        }
        if kqLs.count < soPhieu {
            throw apiErr("getFreeCouponHistory chỉ trả \(kqLs.count) phiếu, không có phiếu số \(soPhieu)")
        }
        let kq = ketQua(soPhieu)
        if !kq.isEmpty && kq != "Y" && kq != "N" {
            throw RunError.skip("Phiếu số \(soPhieu): kết quả sử dụng có giá trị lạ '\(kq)' (không phải Y/N) - bỏ qua để kiểm tra tay.")
        }
        if !kq.isEmpty {
            throw RunError.hasResult("Phiếu số \(soPhieu) đã có kết quả sử dụng ('\(kq)') - bỏ qua theo quy tắc.")
        }
        if soPhieu > 1, let som = (1..<soPhieu).first(where: { ketQua($0).isEmpty }) {
            throw RunError.skip("Phiếu số \(soPhieu) tới hạn hôm nay nhưng phiếu số \(som) chưa có kết quả - không chắc trang sẽ chọn phiếu nào, bỏ qua để kiểm tra tay.")
        }
        return (soPhieu, phieu)
    }

    /// Tra phụ tùng như khi gõ mã trên trang và dựng 1 dòng phụ tùng (SL 1, người dùng trả).
    /// Tồn kho <= Số lượng dừng -> (nil, ghi chú) = KHÔNG thêm phụ tùng.
    static func partRow(_ ch: ApiChannel, pointId: Any?, code raw: String, stopQty: Int?) async throws -> (JSON?, String) {
        let ma = Rules.normPartCode(raw)
        var pb = JSON()
        pb["content"] = ma
        pb["autoFillFlag"] = "Y"
        pb["facilityId"] = nv(pointId)
        pb["pageSize"] = 10
        pb["currentPage"] = 1
        let r = try await call(ch, Paths.parts, pb)
        let list = listOf(lay(lay(r, "data"), "list")).compactMap { $0 as? JSON }
        guard let pt = list.first(where: { Rules.normPartCode(chuoiTho($0["code"])) == ma }) else {
            throw apiErr("không thấy phụ tùng '\(raw)' trong kho điểm bán (partsList không có mã khớp)")
        }
        let onHand = pt["onHandQty"]
        if isNullish(onHand) { throw apiErr("không đọc được tồn kho của phụ tùng '\(raw)'") }
        guard let tonD = soThuc(onHand), tonD.isFinite, abs(tonD) < 1e15 else {
            throw apiErr("tồn kho của phụ tùng '\(raw)' không phải số")
        }
        let ton = Int(tonD)
        if let sl = stopQty, ton <= sl {
            return (nil, "Đã xóa phụ tùng \(raw): tồn kho \(ton) ≤ số lượng dừng \(sl)")
        }
        if ton < 1 { throw apiErr("phụ tùng '\(raw)' hết hàng (tồn kho \(ton)) - không lưu phiếu") }

        var sb = JSON()
        sb["pointId"] = nv(pointId)
        sb["partsCd"] = nv(pt["code"])
        let kho = try await call(ch, Paths.stock, sb)
        let stockQty = lay(lay(kho, "data"), "stockQty")

        let giaChuaThue = Int((soThuc(pt["stdRetailPrice"]) ?? 0).rounded(.toNearestOrEven))
        let thue = soThuc(pt["taxRate"]) ?? 0
        // 106364 + 8% -> 114873 (đúng số trang tính)
        let giaBan = Int(Double(giaChuaThue) * (100.0 + thue) / 100.0 + 0.5)
        let qty = 1
        var thueJson: Any = thue
        if thue == thue.rounded(.towardZero) { thueJson = Int(thue) }

        var row = JSON()
        row["serviceCategoryId"] = "S012REPAIR"
        row["settleTypeId"] = "S013CUSTOMER"
        row["standardPrice"] = giaChuaThue
        row["sellingPrice"] = giaBan
        row["amount"] = giaBan * qty
        row["qty"] = qty
        row["onHandQty"] = ton
        row["boQty"] = 0
        row["shippedQty"] = 0
        row["allocatedQty"] = 0
        row["symptomId"] = NSNull()
        row["partCd"] = nv(pt["code"])
        row["specialPrice"] = NSNull()
        row["ymvnStock"] = ""
        row["locationCd"] = nv(pt["mainLocationCd"])
        row["batteryType"] = NSNull()
        row["_ROW_KEY_"] = "row_\(Int.random(in: 100...199))"
        row["partId"] = pyStr(pt["id"])
        row["partNm"] = nv(pt["name"])
        row["supersedingPartsCdFmt"] = nv(pt["supersedingPartsCdFmt"])
        row["supersedingPartCd"] = nv(pt["supersedingPartsCd"])
        row["supersedingPartNm"] = nv(pt["supersedingPartsNm"])
        row["supersedingPartId"] = nv(pt["supersedingPartsId"])
        row["batteryFlag"] = nv(pt["batteryFlag"])
        row["taxRate"] = thueJson
        row["partStatus"] = nv(pt["partStatus"])
        row["spSalesStatus"] = nv(pt["spSalesStatus"])
        row["locationId"] = nv(pt["mainLocationId"])
        row["sellingPriceNotVat"] = giaChuaThue
        row["actualAmtNotVat"] = giaChuaThue * qty
        row["ymvnStockQty"] = nv(stockQty)
        return (row, "")
    }

    struct Prep {
        var tech: JSON
        var ticket: Int
        var km: Int
        var price: Int
        var jobCode: String
        var parts: [JSON]
        var moto: JSON
        var saveBody: JSON
        var newPhone: String?
    }

    static func prepare(
        _ ch: ApiChannel,
        _ cache: EmployeeCache,
        _ item: inout MaintItem,
        stop: StopFlag,
        log: (String) -> Void
    ) async throws -> Prep {
        let frame = item.frame
        try stop.check()
        let staff = try await CommonFlow.loadEmployees(ch, cache)
        guard let tech = CommonFlow.findTech(staff, item.tech) else {
            throw apiErr("không thấy KTV '\(item.tech)' trong danh sách nhân viên")
        }

        try stop.check()
        var moto = try await CommonFlow.fetchVehicle(ch, frame, required: ["frameNo", "modelCd", "cmmSerializedProductId", "soldDate"])
        let newPhone = try await CommonFlow.fixPhoneIfWrong(ch, &moto, &item.note, kind: .maintenance, label: label, log: log)

        // Phiếu số mấy + đã dùng chưa
        try stop.check()
        let start = CommonFlow.startTime(moto)
        let (ticket, dongPhieu) = try await pickTicket(ch, moto, today: CommonFlow.fmtDayOnly(start))
        guard let rule = Rules.ticketRule(ticket) else {
            throw apiErr("Không có quy tắc xử lý cho phiếu số \(ticket)")
        }
        let jobCode = chuoi(dongPhieu["jobCode"])
        if jobCode.isEmpty { throw apiErr("demandList không có mã công việc (jobCode) cho phiếu số \(ticket)") }

        try stop.check()
        var cb = JSON()
        cb["jobCd"] = jobCode
        cb["modelCd"] = nv(moto["modelCd"])
        cb["modelTypeId"] = nv(moto["modelTypeId"])
        let j = try await call(ch, Paths.couponDetail, ["orderInfo": cb])
        let cv = dataOf(j)
        if !truthy(cv["id"]) || chuoi(cv["code"]).uppercased() != jobCode.uppercased() {
            throw apiErr("getFreeCouponDetail không trả công việc '\(jobCode)' cho model \(pyStr(moto["modelCd"]))")
        }

        // Phụ tùng (tuỳ chọn)
        var parts: [JSON] = []
        let partCode = item.part.trimmed
        if !partCode.isEmpty {
            try stop.check()
            let (row, note) = try await partRow(ch, pointId: moto["pointId"], code: partCode, stopQty: item.stopQty)
            if let r = row { parts.append(r) }
            CommonFlow.addNote(&item.note, note)
        }
        var khachTra = 0
        for p in parts { khachTra += Int(soThuc(p["amount"]) ?? 0) }

        // Dựng lệnh lưu
        let (kmMin, kmMax) = Rules.kmRange(ticket)
        let km = Int.random(in: kmMin...kmMax)
        let finish = CommonFlow.plus(start, minutes: rule.minutes)
        var don = moto
        don["mileage"] = km
        don["serviceCategoryId"] = "S012FREECOUPON"
        don["serviceDemand"] = "Phiếu số \(ticket)"
        don["serviceDemandId"] = String(ticket)
        don["jobCode"] = jobCode
        try CommonFlow.fillTech(&don, tech)
        don["operationStart"] = CommonFlow.fmt(start)
        don["operationFinish"] = CommonFlow.fmt(finish)
        don["finalAmt"] = khachTra
        don["sumOrderAmt"] = khachTra
        don["dbPolicyResult"] = nv(moto["policyResultFlag"])
        don["stuDate"] = nv(moto["soldDate"])
        don["dbModelTypeId"] = nv(moto["modelTypeId"])
        don["newVoucherFlag"] = false
        don["appraisalTargetInput"] = NSNull()
        don["settleTypeId"] = "S013FACTORY"
        don["demandType"] = "DEMAND"
        if var vl = don["voucherList"] as? [Any], let first = vl.first as? JSON {
            var f = first
            f["_ROW_KEY_"] = "row_\(Int.random(in: 50...99))"
            vl[0] = f
            don["voucherList"] = vl
        }

        var dong = JSON()
        dong["serviceCategoryId"] = "S012FREECOUPON"
        dong["serviceDemandContent"] = "Phiếu số \(ticket)"
        dong["serviceDemandId"] = String(ticket)
        dong["settleTypeId"] = "S013FACTORY"
        dong["manhour"] = pyStr(cv["manHours"])
        dong["standardPrice"] = nv(cv["stdRetailPrice"])
        dong["sellingPrice"] = rule.price
        dong["jobCd"] = nv(cv["code"])
        dong["jobId"] = pyStr(cv["id"])
        dong["jobNm"] = nv(cv["name"])
        dong["taxRate"] = nv(cv["vatRate"])
        dong["discount"] = NSNull()
        dong["specialPrice"] = rule.price
        dong["symptomId"] = NSNull()
        dong["discountAmt"] = NSNull()
        dong["servicePackageNm"] = NSNull()
        dong["_ROW_KEY_"] = "row_\(Int.random(in: 50...99))"

        var jobList = CommonFlow.emptyPack()
        jobList["insertRecords"] = [dong]
        var partList = CommonFlow.emptyPack()
        partList["insertRecords"] = parts
        var body = JSON()
        body["orderInfo"] = don
        body["situationList"] = CommonFlow.emptyPack()
        body["jobList"] = jobList
        body["partList"] = partList
        body["batteryList"] = [Any]()
        body["partDetailList"] = parts
        try stop.check()
        return Prep(tech: tech, ticket: ticket, km: km, price: rule.price, jobCode: jobCode, parts: parts, moto: moto, saveBody: body, newPhone: newPhone)
    }

    /// Nhập liệu BT 1 xe. Trả Số Đơn hàng. Quy ước lỗi giống RepairFlow.create.
    static func create(
        _ ch: ApiChannel,
        _ cache: EmployeeCache,
        _ item: inout MaintItem,
        stop: StopFlag,
        log: (String) -> Void
    ) async throws -> String {
        let cb: Prep
        do {
            cb = try await prepare(ch, cache, &item, stop: stop, log: log)
        } catch {
            throw toNotSaved(error)
        }

        // ===== TỪ ĐÂY: lệnh LƯU =====
        let pt = cb.parts.isEmpty ? "không" : item.part
        log("  [\(label)] Xe \(item.frame): lưu Phiếu số \(cb.ticket) (KTV \(pyStr(cb.tech["code"])), Km \(cb.km), CV \(cb.jobCode), giá \(cb.price), phụ tùng \(pt))...")
        let saved = try await call(ch, Paths.save, cb.saveBody)
        let code = saved["data"]
        if !truthy(code) { throw apiErr("saveOrderInfo không trả về mã phiếu (serviceOrderId)") }
        let detail = try await CommonFlow.reloadOrder(ch, cb.moto, code, item.frame)
        let orderNo = chuoi(detail["orderNo"])
        if orderNo.isEmpty {
            throw apiErr("đã lưu phiếu (serviceOrderId=\(pyStr(code))) nhưng không đọc được Số Đơn hàng - KIỂM TRA TAY trên A1-Stream")
        }
        var canhBao: [String] = []
        if let sdt = cb.newPhone, chuoi(detail["mobilephone"]) != sdt {
            canhBao.append("CẢNH BÁO: đã gửi đổi SĐT thành \(sdt) nhưng sau khi lưu phiếu hiển thị '\(pyStr(detail["mobilephone"]))' - kiểm tra tay")
        }
        if !cb.parts.isEmpty && !truthy(detail["partList"]) {
            canhBao.append("CẢNH BÁO: đã gửi phụ tùng \(item.part) nhưng phiếu đọc lại không có dòng phụ tùng - kiểm tra tay")
        }
        if !truthy(detail["jobList"]) {
            canhBao.append("CẢNH BÁO: phiếu đọc lại không có dòng công việc - kiểm tra tay")
        }
        for c in canhBao {
            log("  [\(label)] \(c)")
            CommonFlow.addNote(&item.note, c)
        }
        await CommonFlow.callYas(ch, code: code, moto: cb.moto, frame: item.frame, km: cb.km, label: label, log: log)
        log("  Số Đơn hàng vừa tạo (API): \(orderNo)")
        return orderNo
    }

    /// Làm 1 xe Nhập liệu BT. Bất kỳ sai sót nào -> BỎ QUA XE NGAY (không thử lại), ghi lý do.
    static func one(
        _ session: ApiSession,
        _ cache: EmployeeCache,
        _ item: inout MaintItem,
        stop: StopFlag,
        log: (String) -> Void,
        status: (String) -> Void
    ) async throws -> StepResult {
        item.note = ""
        guard let ch = try await session.getChannel(refresh: false, stop: stop, log: log) else {
            return StepResult(
                result: ItemResult.failed("API: không lấy được token (đã đăng nhập A1-Stream chưa?)"),
                stopAll: false
            )
        }
        status("Xe \(item.frame): đang nhập liệu bằng API...")
        let res: ItemResult
        do {
            let orderNo = try await create(ch, cache, &item, stop: stop, log: log)
            res = ItemResult.success(orderNo, item.note)
        } catch let e as RunError {
            switch e {
            case .stopped:
                throw e
            case .notSaved(let a):
                if let c = a.httpCode, c == 401 || c == 403 {
                    // Xe này vẫn bỏ qua ngay; chỉ bỏ token cũ để XE SAU tự lấy token mới.
                    log("  [API] Phiên/token hết hạn (HTTP \(c)) -> bỏ xe \(item.frame), xe sau sẽ lấy token mới.")
                    await session.close()
                }
                res = ItemResult.failed("API (chưa lưu phiếu): \(a.message)")
            case .hasResult(let m):
                log("Xe \(item.frame): BỎ QUA THEO QUY TẮC - \(m)")
                res = ItemResult.skipped(m)
            case .skip(let m):
                log("Xe \(item.frame): BỎ QUA THEO QUY TẮC - \(m)")
                res = ItemResult.skipped(m)
            case .api(let a):
                res = ItemResult.failed("API (CÓ THỂ ĐÃ LƯU PHIẾU, kiểm tra tay trước khi chạy lại): \(a.message)")
            }
        } catch {
            res = ItemResult.failed("Lỗi không lường trước (CÓ THỂ ĐÃ LƯU PHIẾU, kiểm tra tay trước khi chạy lại): \(errText(error))")
        }
        return StepResult(result: res, stopAll: false)
    }
}
