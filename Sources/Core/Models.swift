import Foundation

struct ApiError: Error {
    var message: String
    var httpCode: Int? = nil
    var raw: String? = nil
}

enum RunError: Error {
    /// Người dùng bấm "Dừng ngay".
    case stopped
    /// Lỗi API. Ở các chế độ GHI: lỗi SAU lệnh lưu (có thể phiếu đã tạo).
    case api(ApiError)
    /// Lỗi TRƯỚC lệnh ghi -> chắc chắn chưa tạo/kết thúc gì.
    case notSaved(ApiError)
    /// Bỏ qua theo quy tắc nghiệp vụ.
    case skip(String)
    /// Phiếu đã có kết quả sử dụng Y/N.
    case hasResult(String)
}

struct AppError: Error {
    var message: String
}

func apiErr(_ m: String) -> RunError {
    return RunError.api(ApiError(message: m))
}

func errText(_ e: Error) -> String {
    if let r = e as? RunError {
        switch r {
        case .stopped: return "Người dùng yêu cầu dừng ngay."
        case .api(let a): return a.message
        case .notSaved(let a): return a.message
        case .skip(let m): return m
        case .hasResult(let m): return m
        }
    }
    if let a = e as? AppError { return a.message }
    return e.localizedDescription
}

/// Lỗi API trong giai đoạn chuẩn bị -> coi là "chưa lưu".
func toNotSaved(_ e: Error) -> Error {
    if let r = e as? RunError, case .api(let a) = r { return RunError.notSaved(a) }
    return e
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ v: Bool) {
        lock.lock(); value = v; lock.unlock()
    }
    func check() throws {
        if isSet { throw RunError.stopped }
    }
}

// MARK: - Chế độ

enum Mode: String, CaseIterable, Identifiable, Hashable {
    case check, repair, maintenance, settle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .check: return "Kiểm tra xe"
        case .repair: return "Sửa chữa"
        case .maintenance: return "Nhập liệu BT"
        case .settle: return "Kết thúc BT/DV"
        }
    }
    var shortTitle: String {
        switch self {
        case .check: return "Kiểm tra"
        case .repair: return "Sửa chữa"
        case .maintenance: return "Nhập BT"
        case .settle: return "Kết thúc"
        }
    }
    var symbol: String {
        switch self {
        case .check: return "checkmark.shield"
        case .repair: return "wrench.and.screwdriver"
        case .maintenance: return "doc.text"
        case .settle: return "flag.checkered"
        }
    }
    var writes: Bool { self != .check }

    var detail: String {
        switch self {
        case .check: return "Chỉ đọc – không lưu, không tạo phiếu. Kiểm tra SĐT và chính sách quyền riêng tư của từng số khung."
        case .repair: return "TẠO PHIẾU SỬA CHỮA THẬT. Mỗi dòng: Số khung, KTV, Mã Công Việc, Số Tiền (Giá bán đặc biệt)."
        case .maintenance: return "TẠO PHIẾU BẢO TRÌ THẬT. Mỗi dòng: Số khung, KTV, Phụ tùng (có thể bỏ trống). Km, giá, phút kết thúc tự tính theo số phiếu."
        case .settle: return "KẾT THÚC phiếu thật (Wait for settle → Completed). Mỗi dòng 1 Số Đơn hàng."
        }
    }
    var inputTitle: String {
        switch self {
        case .check: return "Danh sách số khung (mỗi dòng 1 xe)"
        case .repair: return "Số khung | KTV | Mã Công Việc | Số Tiền"
        case .maintenance: return "Số khung | KTV | Phụ tùng"
        case .settle: return "Danh sách Số Đơn hàng (mỗi dòng 1 đơn)"
        }
    }
    var hint: String {
        switch self {
        case .check: return "Dán danh sách số khung vào đây, mỗi dòng 1 số.\nVD:\nRLCTEST0000000001\nRLCTEST0000000002"
        case .repair: return "Dán từ Excel/Sheets (cột cách nhau bằng Tab) hoặc gõ phân cách bằng dấu phẩy.\nVD:\nRLCTEST0000000001, KTV01, MA_CV_1, 150000"
        case .maintenance: return "Dán từ Excel/Sheets hoặc gõ phân cách bằng dấu phẩy. Phụ tùng có thể bỏ trống.\nVD:\nRLCTEST0000000001, KTV01, 90793-AV912\nRLCTEST0000000002, KTV01"
        case .settle: return "Dán Số Đơn hàng, mỗi dòng 1 đơn.\nHoặc bấm nút lấy số đơn từ lần chạy Sửa chữa / Nhập liệu BT trước."
        }
    }
    var sample: String {
        switch self {
        case .check: return "RLCTEST0000000001\nRLCTEST0000000002"
        case .repair: return "RLCTEST0000000001, KTV01, MA_CV_1, 150000\nRLCTEST0000000002, KTV01, MA_CV_2, 200000"
        case .maintenance: return "RLCTEST0000000001, KTV01, 90793-AV912\nRLCTEST0000000002, KTV01"
        case .settle: return "SO-DON-HANG-1\nSO-DON-HANG-2"
        }
    }
    var defaultGap: Double { self == .check ? 1.0 : Rules.defaultGap }
    var csvPrefix: String {
        switch self {
        case .check: return "kiem_tra_xe"
        case .repair: return "sua_chua_ket_qua"
        case .maintenance: return "nhap_lieu_bt_ket_qua"
        case .settle: return "ket_thuc_dv"
        }
    }
    var countLabels: [String] {
        self == .check ? ["Đủ tiêu chuẩn", "Không đủ", "Lỗi tra cứu"] : ["Thành công", "Thất bại", "Bỏ qua"]
    }
}

// MARK: - Kết quả

enum ItemStatus {
    case success, failed, pending

    var text: String {
        switch self {
        case .success: return "Thành công"
        case .failed: return "Thất bại"
        case .pending: return "Chưa xử lý"
        }
    }
}

struct ItemResult {
    var status: ItemStatus
    var reason: String
    var orderNo: String
    var skipped: Bool

    static func pending() -> ItemResult {
        return ItemResult(status: .pending, reason: "", orderNo: "", skipped: false)
    }
    static func success(_ orderNo: String, _ note: String) -> ItemResult {
        return ItemResult(status: .success, reason: note, orderNo: orderNo, skipped: false)
    }
    static func failed(_ reason: String) -> ItemResult {
        return ItemResult(status: .failed, reason: reason, orderNo: "", skipped: false)
    }
    static func skipped(_ reason: String) -> ItemResult {
        return ItemResult(status: .failed, reason: "Bỏ qua: " + reason, orderNo: "", skipped: true)
    }
}

/// Kết quả 1 mục + cờ "dừng cả đợt" (vd không lấy được token).
struct StepResult {
    var result: ItemResult
    var stopAll: Bool
}

// MARK: - Dữ liệu từng chế độ

struct RepairItem {
    var frame: String
    var tech: String
    var jobCode: String
    /// Chỉ chữ số.
    var amount: String
    var note: String = ""
}

struct MaintItem {
    var frame: String
    var tech: String
    var part: String
    var stopQty: Int?
    var note: String = ""
}

enum Verdict {
    static let ok = "Đủ tiêu chuẩn"
    static let notOK = "Không đủ tiêu chuẩn"
    static let lookupError = "Lỗi tra cứu"
    static let notChecked = "Chưa kiểm tra"
}

struct CheckResult {
    var frame: String
    var name = ""
    var phone = ""
    var phoneState = ""
    var policy = ""
    var policyValue = ""
    var model = ""
    var soldDate = ""
    var verdict = ""
    var reason = ""

    static func failure(_ frame: String, _ reason: String) -> CheckResult {
        var k = CheckResult(frame: frame)
        k.verdict = Verdict.lookupError
        k.reason = reason
        return k
    }
    static func notChecked(_ frame: String) -> CheckResult {
        var k = CheckResult(frame: frame)
        k.verdict = Verdict.notChecked
        return k
    }
}

// MARK: - Hàng hiển thị

enum RowKind { case good, bad, warn }

struct ResultRow {
    var kind: RowKind
    var verdict: String
    var reason: String
    var orderNo: String

    var detail: String {
        switch (orderNo.isEmpty, reason.isEmpty) {
        case (true, true): return ""
        case (false, true): return "Đơn hàng \(orderNo)"
        case (true, false): return reason
        case (false, false): return "Đơn hàng \(orderNo) · \(reason)"
        }
    }

    static func from(_ r: ItemResult) -> ResultRow {
        switch (r.status, r.skipped) {
        case (.success, _): return ResultRow(kind: .good, verdict: "Thành công", reason: r.reason, orderNo: r.orderNo)
        case (.failed, true): return ResultRow(kind: .warn, verdict: "Bỏ qua", reason: r.reason, orderNo: r.orderNo)
        case (.failed, false): return ResultRow(kind: .bad, verdict: "Thất bại", reason: r.reason, orderNo: r.orderNo)
        case (.pending, _): return ResultRow(kind: .warn, verdict: "Chưa xử lý", reason: r.reason, orderNo: r.orderNo)
        }
    }

    static func from(_ k: CheckResult) -> ResultRow {
        let kind: RowKind
        if k.verdict == Verdict.ok { kind = .good }
        else if k.verdict == Verdict.notOK { kind = .bad }
        else { kind = .warn }
        return ResultRow(kind: kind, verdict: k.verdict, reason: k.reason, orderNo: "")
    }
}

enum RowState {
    case waiting
    case running(String)
    case done(ResultRow)
}

struct Row: Identifiable {
    let id = UUID()
    var key: String
    var sub: String
    var state: RowState
}
