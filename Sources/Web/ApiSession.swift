import Foundation

/// Giữ kênh API của 1 đợt chạy. Hết hạn token thì bỏ kênh cũ, lần sau tự lấy lại.
@MainActor
final class ApiSession {
    private var channel: ApiChannel?
    private var failedAt: Date?

    /// nil = không lấy được kênh (đã báo lý do vào nhật ký). Chỉ "Dừng" mới throw.
    func getChannel(refresh: Bool, stop: StopFlag, log: (String) -> Void) async throws -> ApiChannel? {
        if refresh { await close() }
        if channel == nil {
            if let t = failedAt, Date().timeIntervalSince(t) < 90 { return nil }
            do {
                channel = try await WebSession.shared.prepareChannel(stop: stop, log: log)
                failedAt = nil
            } catch let e as RunError {
                if case .stopped = e { throw e }
                log("[API] Không khởi tạo được kênh API: \(errText(e))")
                failedAt = Date()
                return nil
            } catch {
                log("[API] Không khởi tạo được kênh API: \(errText(error))")
                failedAt = Date()
                return nil
            }
        }
        return channel
    }

    func close() async {
        if let c = channel { await c.close() }
        channel = nil
    }
}
