import Foundation

typealias JSON = [String: Any]

// MARK: - Kiểu giá trị (giống cách Python/serde_json xử lý)

func isBoolValue(_ v: Any) -> Bool {
    if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() }
    return false
}

func isNullish(_ v: Any?) -> Bool {
    guard let v = v else { return true }
    return v is NSNull
}

/// Số thực -> chữ giống Python: 1.0 -> "1.0", 1 -> "1", 0.5 -> "0.5".
func numberString(_ n: NSNumber) -> String {
    if CFNumberIsFloatType(n as CFNumber) {
        let d = n.doubleValue
        if d == d.rounded() && abs(d) < 1e15 { return String(format: "%.1f", d) }
        return "\(d)"
    }
    return n.stringValue
}

func jsonString(_ v: Any) -> String {
    if JSONSerialization.isValidJSONObject(v),
       let d = try? JSONSerialization.data(withJSONObject: v, options: [.withoutEscapingSlashes]),
       let s = String(data: d, encoding: .utf8) {
        return s
    }
    return "\(v)"
}

/// Giá trị "thật" theo kiểu Python: không null, không "", không 0, không false, không [] / {}.
func truthy(_ v: Any?) -> Bool {
    guard let v = v, !(v is NSNull) else { return false }
    if isBoolValue(v) { return (v as? Bool) ?? false }
    if let s = v as? String { return !s.isEmpty }
    if let n = v as? NSNumber { return n.doubleValue != 0 }
    if let a = v as? [Any] { return !a.isEmpty }
    if let d = v as? [String: Any] { return !d.isEmpty }
    return true
}

/// `str(v or "").strip()`
func chuoi(_ v: Any?) -> String {
    if !truthy(v) { return "" }
    return chuoiTho(v).trimmed
}

/// `str(v or "")` (không cắt khoảng trắng)
func chuoiTho(_ v: Any?) -> String {
    if !truthy(v) { return "" }
    guard let v = v else { return "" }
    if let s = v as? String { return s }
    if isBoolValue(v) { return "true" }
    if let n = v as? NSNumber { return numberString(n) }
    return jsonString(v)
}

/// `str(v)` của Python: None -> "None", True -> "True".
func pyStr(_ v: Any?) -> String {
    guard let v = v, !(v is NSNull) else { return "None" }
    if isBoolValue(v) { return ((v as? Bool) ?? false) ? "True" : "False" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return numberString(n) }
    return jsonString(v)
}

/// Thiếu khoá -> "", ngược lại như pyStr.
func pyStrIfPresent(_ v: Any?) -> String {
    guard let v = v else { return "" }
    return pyStr(v)
}

/// Chữ thô để ghi ra file (null -> "", true -> "true").
func rawString(_ v: Any?) -> String {
    guard let v = v, !(v is NSNull) else { return "" }
    if let s = v as? String { return s }
    if isBoolValue(v) { return ((v as? Bool) ?? false) ? "true" : "false" }
    if let n = v as? NSNumber { return numberString(n) }
    return jsonString(v)
}

func soThuc(_ v: Any?) -> Double? {
    guard let v = v, !(v is NSNull), !isBoolValue(v) else { return nil }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s.trimmed) }
    return nil
}

/// v[k]
func lay(_ v: Any?, _ k: String) -> Any? {
    guard let d = v as? [String: Any] else { return nil }
    return d[k]
}

/// Thiếu -> NSNull (để khoá vẫn còn trong JSON gửi đi).
func nv(_ v: Any?) -> Any {
    if let v = v { return v }
    return NSNull()
}

/// `j.get("data") or {}`
func dataOf(_ j: JSON) -> JSON {
    if let d = j["data"] as? JSON, !d.isEmpty { return d }
    return [:]
}

func listOf(_ v: Any?) -> [Any] {
    return (v as? [Any]) ?? []
}

func parseJSON(_ text: String) -> Any? {
    guard let d = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
}

func toJSONData(_ obj: Any) -> Data? {
    guard JSONSerialization.isValidJSONObject(obj) else { return nil }
    return try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
}

/// Số thực tròn (114873.0) -> số nguyên (114873) trên toàn bộ cây JSON.
func normalizeNumbers(_ v: Any) -> Any {
    if isBoolValue(v) { return v }
    if let n = v as? NSNumber {
        if CFNumberIsFloatType(n as CFNumber) {
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 9.0e15 { return Int(d) }
        }
        return v
    }
    if let a = v as? [Any] { return a.map { normalizeNumbers($0) } }
    if let d = v as? [String: Any] { return d.mapValues { normalizeNumbers($0) } }
    return v
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
