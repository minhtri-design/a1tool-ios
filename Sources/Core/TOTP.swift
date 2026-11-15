import Foundation
import CryptoKit

/// Mã TOTP 6 số (RFC 6238, SHA-1, 30 giây) từ khoá bí mật Base32.
enum TOTP {

    static func base32Decode(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt32 = 0
        var bits = 0
        var out = Data()
        let clean = s.uppercased().filter { $0 != " " && $0 != "-" && $0 != "=" }
        if clean.isEmpty { return nil }
        for ch in clean {
            guard let v = alphabet.firstIndex(of: ch) else { return nil }
            buffer = (buffer << 5) | UInt32(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }

    static func code(secret: String, at time: TimeInterval) -> String? {
        guard let keyData = base32Decode(secret), !keyData.isEmpty else { return nil }
        let counter = UInt64(time / 30.0)
        var be = counter.bigEndian
        let msg = withUnsafeBytes(of: &be) { Data($0) }
        let key = SymmetricKey(data: keyData)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key)
        let h = Array(mac)
        if h.count < 20 { return nil }
        let o = Int(h[h.count - 1] & 0x0f)
        let b0 = UInt32(h[o] & 0x7f) << 24
        let b1 = UInt32(h[o + 1]) << 16
        let b2 = UInt32(h[o + 2]) << 8
        let b3 = UInt32(h[o + 3])
        let bin = b0 | b1 | b2 | b3
        let v = bin % 1_000_000
        return String(format: "%06d", v)
    }

    /// Mã mới nhất, không trùng mã đã dùng; nếu sắp hết 30 giây thì chờ sang chu kỳ mới.
    static func freshCode(secret: String, previous: String?, stop: StopFlag) async throws -> String {
        while true {
            try stop.check()
            let now = Date().timeIntervalSince1970
            let remain = 30.0 - now.truncatingRemainder(dividingBy: 30.0)
            if remain < 3.0 {
                try? await Task.sleep(nanoseconds: UInt64((remain + 0.3) * 1_000_000_000))
                continue
            }
            guard let c = code(secret: secret, at: now) else {
                throw AppError(message: "Khoá TOTP không hợp lệ (cần chuỗi Base32).")
            }
            if let p = previous, p == c {
                try? await Task.sleep(nanoseconds: UInt64((remain + 0.3) * 1_000_000_000))
                continue
            }
            return c
        }
    }
}
