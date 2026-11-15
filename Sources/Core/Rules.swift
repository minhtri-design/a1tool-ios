import Foundation

/// Quy tắc nghiệp vụ (cổng từ bản Rust/Python).
enum Rules {
    static let appDomain = "yamaha-motor-ymvn-a1-stream.com"
    static let targetURL = "https://yamaha-motor-ymvn-a1-stream.com/service/job/svm0102_01"
    static let apiRoot = "/a1stream/api"
    static let loginDomain = "amazoncognito.com"

    static let kmRepairMin = 30000
    static let kmRepairMax = 75000
    static let repairExtraMinutes = 30
    static let defaultGap: Double = 5.0

    private static let validPrefixes: Set<String> = [
        "032", "033", "034", "035", "036", "037", "038", "039", "052", "055", "056", "058", "059", "070",
        "076", "077", "078", "079", "081", "082", "083", "084", "085", "086", "087", "088", "089", "090",
        "091", "092", "093", "094", "095", "096", "097", "098", "099",
    ]

    /// SĐT thay thế theo từ cuối của tên khách hàng.
    static func replacementPhone(_ lastWord: String) -> String? {
        switch lastWord.uppercased() {
        case "DUY": return "0935899588"
        case "THY": return "0905439439"
        default: return nil
        }
    }

    /// (số phút cộng thêm, giá đặc biệt) theo số phiếu bảo dưỡng.
    static func ticketRule(_ n: Int) -> (minutes: Int, price: Int)? {
        switch n {
        case 1: return (30, 33000)
        case 2, 4, 5, 7, 8: return (60, 65000)
        case 3, 6, 9: return (90, 93000)
        default: return nil
        }
    }

    /// Khoảng Km random theo số phiếu.
    static func kmRange(_ n: Int) -> (Int, Int) {
        if n == 1 { return (500, 1000) }
        return (n * 3000 - 2000, n * 3000 + 1000)
    }

    static func allDigits(_ s: String) -> Bool {
        return !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// nil = hợp lệ; ngược lại trả lý do sai.
    static func checkPhone(_ raw: String) -> String? {
        let so = raw.trimmed
        if so.isEmpty { return "số điện thoại đang trống" }
        if !so.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return "số điện thoại '\(so)' chứa ký tự không phải chữ số"
        }
        let n = so.count
        if n != 10 { return "số điện thoại '\(so)' có \(n) số (cần đủ 10 số)" }
        let dau = String(so.prefix(3))
        if !validPrefixes.contains(dau) { return "số điện thoại '\(so)' có đầu số \(dau) không hợp lệ" }
        return nil
    }

    /// Đã đồng ý chính sách quyền riêng tư?
    static func policyAgreed(_ v: Any?) -> Bool {
        guard let v = v, !(v is NSNull) else { return false }
        if isBoolValue(v) { return (v as? Bool) ?? false }
        let s: String
        if let str = v as? String {
            s = str
        } else if let n = v as? NSNumber {
            s = numberString(n)
        } else {
            s = jsonString(v)
        }
        let khong: Set<String> = ["", "N", "0", "NO", "FALSE", "NULL", "NONE"]
        return !khong.contains(s.trimmed.uppercased())
    }

    static func boDau(_ s: String) -> String {
        let r = s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
        let folded = r.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Mã phụ tùng chuẩn hoá để so khớp ('90793-av912' == '90793AV912').
    static func normPartCode(_ s: String) -> String {
        return String(s.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// Tên khách hàng = lastName + middleName + firstName, tách theo khoảng trắng.
    static func nameWords(_ moto: JSON) -> [String] {
        let ghep = ["lastName", "middleName", "firstName"].map { chuoi(moto[$0]) }.joined(separator: " ")
        return ghep.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }

    /// "yyyymmdd..." -> "dd/mm/yyyy"
    static func formatDate(_ raw: String) -> String {
        let s = raw.trimmed
        let c = Array(s)
        if c.count >= 8 && c[0..<8].allSatisfy({ $0.isASCII && $0.isNumber }) {
            let d = String(c[6..<8]), m = String(c[4..<6]), y = String(c[0..<4])
            return "\(d)/\(m)/\(y)"
        }
        return s
    }
}
