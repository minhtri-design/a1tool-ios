import Foundation

struct ParseOut<T> {
    var items: [T] = []
    /// Dòng bị bỏ vì sai định dạng / trùng.
    var dropped: [String] = []
    /// Cảnh báo (vẫn làm).
    var warnings: [String] = []

    var infoLines: [String] { return dropped + warnings }
}

/// Đọc danh sách người dùng dán vào (từ Excel/Sheets: các cột cách nhau bằng Tab; hoặc gõ tay cách nhau bằng dấu phẩy / chấm phẩy / | / khoảng trắng).
enum InputParser {

    static func cells(_ line: String, splitSpaces: Bool) -> [String] {
        var parts: [String]
        if line.contains("\t") {
            parts = line.components(separatedBy: "\t")
        } else if line.contains(";") {
            parts = line.components(separatedBy: ";")
        } else if line.contains(",") {
            parts = line.components(separatedBy: ",")
        } else if line.contains("|") {
            parts = line.components(separatedBy: "|")
        } else if splitSpaces {
            parts = line.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        } else {
            parts = [line]
        }
        let quotes = CharacterSet(charactersIn: "\"“”")
        return parts.map { $0.trimmingCharacters(in: quotes).trimmed }
    }

    /// Các dòng không rỗng, đã bỏ dòng tiêu đề (nếu có).
    static func rows(_ text: String, splitSpaces: Bool) -> [(Int, [String])] {
        var out: [(Int, [String])] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmed
            if line.isEmpty { continue }
            let c = cells(line, splitSpaces: splitSpaces)
            if c.allSatisfy({ $0.isEmpty }) { continue }
            out.append((idx + 1, c))
        }
        if let first = out.first, let cell = first.1.first {
            let b = Rules.boDau(cell)
            if b.hasPrefix("so khung") || b.hasPrefix("so don hang") || b == "khung" || b.hasPrefix("frame") {
                out.removeFirst()
            }
        }
        return out
    }

    static func frameWarning(_ f: String) -> String? {
        if f.contains(where: { $0.isWhitespace }) { return "số khung '\(f)' có khoảng trắng" }
        if f.count < 10 || f.count > 20 { return "số khung '\(f)' có \(f.count) ký tự (bất thường)" }
        return nil
    }

    // MARK: Kiểm tra xe

    static func frames(_ text: String) -> ParseOut<String> {
        var out = ParseOut<String>()
        var seen = Set<String>()
        for (n, c) in rows(text, splitSpaces: false) {
            let f = (c.first ?? "").trimmed
            if f.isEmpty { continue }
            if seen.contains(f.uppercased()) {
                out.dropped.append("Dòng \(n): số khung \(f) bị trùng - bỏ qua")
                continue
            }
            seen.insert(f.uppercased())
            if let w = frameWarning(f) { out.warnings.append("Dòng \(n): \(w)") }
            out.items.append(f)
        }
        return out
    }

    // MARK: Sửa chữa

    static func repairs(_ text: String) -> ParseOut<RepairItem> {
        var out = ParseOut<RepairItem>()
        var seen = Set<String>()
        for (n, c) in rows(text, splitSpaces: true) {
            let frame = c.count > 0 ? c[0] : ""
            let tech = c.count > 1 ? c[1] : ""
            let job = c.count > 2 ? c[2] : ""
            // Số tiền: ghép phần còn lại (để "150,000" hay "150 000" không bị tách nhầm).
            let amountRaw = c.count > 3 ? c.dropFirst(3).joined() : ""
            if frame.isEmpty || tech.isEmpty || job.isEmpty || amountRaw.isEmpty {
                out.dropped.append("Dòng \(n): thiếu cột (cần Số khung, KTV, Mã Công Việc, Số Tiền) - bỏ dòng")
                continue
            }
            let okChars = amountRaw.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "," || $0 == " " }
            let digits = String(amountRaw.filter { $0.isASCII && $0.isNumber })
            if !okChars || digits.isEmpty {
                out.dropped.append("Dòng \(n): Số Tiền '\(amountRaw)' không hợp lệ - bỏ dòng")
                continue
            }
            if seen.contains(frame.uppercased()) {
                out.dropped.append("Dòng \(n): số khung \(frame) bị trùng - bỏ dòng (tránh tạo 2 phiếu)")
                continue
            }
            seen.insert(frame.uppercased())
            if let w = frameWarning(frame) { out.warnings.append("Dòng \(n): \(w)") }
            out.items.append(RepairItem(frame: frame, tech: tech, jobCode: job, amount: digits))
        }
        return out
    }

    // MARK: Nhập liệu BT

    /// Bảng "Mã phụ tùng, Số lượng dừng": mỗi dòng 2 cột. Trả (bảng, cảnh báo).
    static func stopTable(_ text: String) -> ([String: Int], [String]) {
        var table: [String: Int] = [:]
        var warns: [String] = []
        for (n, c) in rows(text, splitSpaces: true) {
            if c.count < 2 { warns.append("Bảng số lượng dừng dòng \(n): thiếu cột - bỏ"); continue }
            let ma = Rules.normPartCode(c[0])
            guard let q = Int(c[1].trimmed), q >= 0 else {
                if n == 1 { continue }   // có thể là dòng tiêu đề
                warns.append("Bảng số lượng dừng dòng \(n): số lượng '\(c[1])' không phải số nguyên - bỏ")
                continue
            }
            if ma.isEmpty { continue }
            if table[ma] != nil { warns.append("Bảng số lượng dừng: mã \(c[0]) bị trùng, giữ dòng đầu"); continue }
            table[ma] = q
        }
        return (table, warns)
    }

    static func maintenance(_ text: String, stopTable: [String: Int]) -> ParseOut<MaintItem> {
        var out = ParseOut<MaintItem>()
        var seen = Set<String>()
        for (n, c) in rows(text, splitSpaces: true) {
            let frame = c.count > 0 ? c[0] : ""
            let tech = c.count > 1 ? c[1] : ""
            // Phụ tùng: ghép phần còn lại ("90793 AV912" -> "90793AV912").
            let part = c.count > 2 ? c.dropFirst(2).joined() : ""
            if frame.isEmpty || tech.isEmpty {
                out.dropped.append("Dòng \(n): thiếu cột (cần Số khung, KTV) - bỏ dòng")
                continue
            }
            if seen.contains(frame.uppercased()) {
                out.dropped.append("Dòng \(n): số khung \(frame) bị trùng - bỏ dòng (tránh tạo 2 phiếu)")
                continue
            }
            seen.insert(frame.uppercased())
            if let w = frameWarning(frame) { out.warnings.append("Dòng \(n): \(w)") }
            let stopQty: Int? = part.isEmpty ? nil : stopTable[Rules.normPartCode(part)]
            out.items.append(MaintItem(frame: frame, tech: tech, part: part, stopQty: stopQty))
        }
        return out
    }

    // MARK: Kết thúc

    static func orders(_ text: String) -> ParseOut<String> {
        var out = ParseOut<String>()
        var seen = Set<String>()
        for (n, c) in rows(text, splitSpaces: false) {
            let no = (c.first ?? "").trimmed
            if no.isEmpty { continue }
            if seen.contains(no) {
                out.dropped.append("Dòng \(n): Số Đơn hàng \(no) bị trùng - bỏ qua")
                continue
            }
            seen.insert(no)
            out.items.append(no)
        }
        return out
    }
}
