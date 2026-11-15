import SwiftUI
import UIKit

enum RunPayload {
    case check([String])
    case repair([RepairItem])
    case maintenance([MaintItem])
    case settle([String])
}

struct PendingConfirm {
    let mode: Mode
    let count: Int
    let infoLines: [String]
    let payload: RunPayload

    var message: String {
        let viec = mode == .settle ? "KẾT THÚC" : "TẠO PHIẾU"
        var s = "Sẽ \(viec) THẬT cho \(count) mục. Thao tác ghi vào A1-Stream và không hoàn tác được."
        if !infoLines.isEmpty { s += "\n\(infoLines.count) dòng bị bỏ hoặc có cảnh báo (xem Nhật ký sau khi chạy)." }
        s += "\nGiữ màn hình iPad sáng và mở app trong suốt lúc chạy."
        return s
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: Mode = .check
    @Published var inputs: [Mode: String] = [:] { didSet { persistInputs() } }
    @Published var stopQtyText: String = "" { didSet { UserDefaults.standard.set(stopQtyText, forKey: "stopQtyText") } }
    @Published var gaps: [Mode: Double] = [:] { didSet { persistGaps() } }
    @Published var rows: [Mode: [Row]] = [:]
    @Published var notes: [Mode: String] = [:]
    @Published var exportURL: [Mode: URL] = [:]
    @Published var log: [String] = []
    @Published var running: Mode? = nil
    @Published var stopping = false
    @Published var pending: PendingConfirm? = nil
    @Published var lastOrders: [String] = []
    @Published var loginStatus: String = "Chưa đăng nhập"

    let stop = StopFlag()
    private let ud = UserDefaults.standard

    init() {
        for m in Mode.allCases {
            if let s = ud.string(forKey: "in_" + m.rawValue) { inputs[m] = s }
            let g = ud.double(forKey: "gap_" + m.rawValue)
            if ud.object(forKey: "gap_" + m.rawValue) != nil { gaps[m] = g }
        }
        stopQtyText = ud.string(forKey: "stopQtyText") ?? ""
        lastOrders = ud.stringArray(forKey: "lastOrders") ?? []
        refreshLoginStatus()
    }

    private func persistInputs() {
        for (m, s) in inputs { ud.set(s, forKey: "in_" + m.rawValue) }
    }

    private func persistGaps() {
        for (m, g) in gaps { ud.set(g, forKey: "gap_" + m.rawValue) }
    }

    func gap(_ m: Mode) -> Double { return gaps[m] ?? m.defaultGap }

    // MARK: Nhật ký / hàng

    func addLog(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("[\(f.string(from: Date()))] \(s)")
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
    }

    func setRowStatus(_ m: Mode, _ i: Int, _ s: String) {
        guard var arr = rows[m], i >= 0, i < arr.count else { return }
        arr[i].state = .running(s)
        rows[m] = arr
    }

    func setRowDone(_ m: Mode, _ i: Int, _ r: ResultRow, sub: String? = nil) {
        guard var arr = rows[m], i >= 0, i < arr.count else { return }
        arr[i].state = .done(r)
        if let s = sub { arr[i].sub = s }
        rows[m] = arr
    }

    private func finalizeWaiting(_ m: Mode, reason: String) {
        guard var arr = rows[m] else { return }
        for i in 0..<arr.count {
            switch arr[i].state {
            case .done: break
            case .waiting, .running:
                arr[i].state = .done(ResultRow(kind: .warn, verdict: "Chưa xử lý", reason: reason, orderNo: ""))
            }
        }
        rows[m] = arr
    }

    func refreshLoginStatus() {
        let url = WebSession.shared.webView.url?.absoluteString ?? ""
        if url.contains(Rules.appDomain) {
            loginStatus = "Đã mở trang A1-Stream"
        } else if url.contains(Rules.loginDomain) {
            loginStatus = "Đang ở màn hình đăng nhập"
        } else {
            loginStatus = "Chưa đăng nhập"
        }
    }

    func autoLogin() async {
        let cred = Credentials.load()
        if cred.username.trimmed.isEmpty || cred.password.isEmpty {
            loginStatus = "Chưa lưu tài khoản (menu ⋯ → Tài khoản đã lưu)"
            return
        }
        loginStatus = "Đang tự đăng nhập..."
        let flag = StopFlag()
        do {
            try await WebSession.shared.autoLogin(cred, stop: flag, log: { s in self.addLog(s) })
            loginStatus = "Đã đăng nhập"
        } catch {
            loginStatus = "Đăng nhập lỗi: \(errText(error))"
            addLog("[Đăng nhập] \(errText(error))")
        }
    }

    // MARK: Điều khiển

    func useLastOrders() {
        inputs[.settle] = lastOrders.joined(separator: "\n")
    }

    func start() {
        guard running == nil else { return }
        let m = mode
        notes[m] = ""
        let text = inputs[m] ?? ""
        switch m {
        case .check:
            let p = InputParser.frames(text)
            if p.items.isEmpty { notes[m] = "Chưa có số khung nào để kiểm tra."; return }
            begin(m, .check(p.items), info: p.infoLines)
        case .repair:
            let p = InputParser.repairs(text)
            if p.items.isEmpty { notes[m] = p.dropped.isEmpty ? "Chưa có dòng nào hợp lệ." : p.dropped.joined(separator: "\n"); return }
            pending = PendingConfirm(mode: m, count: p.items.count, infoLines: p.infoLines, payload: .repair(p.items))
        case .maintenance:
            let (table, tw) = InputParser.stopTable(stopQtyText)
            let p = InputParser.maintenance(text, stopTable: table)
            if p.items.isEmpty { notes[m] = p.dropped.isEmpty ? "Chưa có dòng nào hợp lệ." : p.dropped.joined(separator: "\n"); return }
            pending = PendingConfirm(mode: m, count: p.items.count, infoLines: tw + p.infoLines, payload: .maintenance(p.items))
        case .settle:
            let p = InputParser.orders(text)
            if p.items.isEmpty { notes[m] = "Chưa có Số Đơn hàng nào."; return }
            pending = PendingConfirm(mode: m, count: p.items.count, infoLines: p.infoLines, payload: .settle(p.items))
        }
    }

    func confirmPending() {
        guard let p = pending else { return }
        pending = nil
        begin(p.mode, p.payload, info: p.infoLines)
    }

    func cancelPending() {
        pending = nil
    }

    func requestStop() {
        guard running != nil else { return }
        stop.set(true)
        stopping = true
        addLog("Đã nhận lệnh DỪNG - sẽ dừng ở bước an toàn gần nhất.")
    }

    func copyLog() {
        UIPasteboard.general.string = log.joined(separator: "\n")
    }

    private func begin(_ m: Mode, _ payload: RunPayload, info: [String]) {
        running = m
        stopping = false
        stop.set(false)
        rows[m] = []
        exportURL[m] = nil
        notes[m] = ""
        log.removeAll()
        for l in info { addLog("Lưu ý: \(l)") }
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            switch payload {
            case .check(let f): await self.runCheck(f)
            case .repair(let it): await self.runRepair(it)
            case .maintenance(let it): await self.runMaintenance(it)
            case .settle(let o): await self.runSettle(o)
            }
            self.running = nil
            self.stopping = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: Kiểm tra xe

    private func runCheck(_ frames: [String]) async {
        let m = Mode.check
        rows[m] = frames.map { Row(key: $0, sub: "", state: .waiting) }
        let session = ApiSession()
        var results: [CheckResult] = frames.map { CheckResult.notChecked($0) }
        var lastEnd: Date? = nil
        var stopped = false
        let g = gap(m)
        let logFn: (String) -> Void = { s in self.addLog(s) }

        for (i, frame) in frames.enumerated() {
            if stop.isSet { stopped = true; break }
            do {
                try await CommonFlow.waitGap(seconds: g, since: lastEnd, stop: stop, label: "Xe \(frame)", say: { s in self.setRowStatus(m, i, s) })
            } catch {
                stopped = true
                break
            }
            setRowStatus(m, i, "Đang kiểm tra bằng API...")
            addLog("Xe \(frame): đang kiểm tra bằng API...")
            let out: (CheckResult, Bool)
            do {
                out = try await CheckFlow.one(session, frame, stop: stop, log: logFn)
            } catch {
                if let r = error as? RunError, case .stopped = r {
                    stopped = true
                    setRowDone(m, i, ResultRow(kind: .warn, verdict: "Đã dừng", reason: "Người dùng bấm dừng", orderNo: ""))
                    break
                }
                out = (CheckResult.failure(frame, "API: \(errText(error))"), false)
            }
            lastEnd = Date()
            results[i] = out.0
            setRowDone(m, i, ResultRow.from(out.0), sub: out.0.name)
            addLog("Xe \(frame): \(out.0.verdict)" + (out.0.reason.isEmpty ? "" : " - \(out.0.reason)"))
            if out.1 { addLog("[API] Dừng cả đợt vì không lấy được token."); break }
        }
        await session.close()
        finalizeWaiting(m, reason: stopped ? "Đã dừng trước khi tới xe này" : "Chưa kiểm tra")

        let header = ["Số khung", "Khách hàng", "SĐT", "SĐT hợp lệ", "Chính sách", "Giá trị chính sách", "Model", "Ngày bán", "Kết luận", "Lý do"]
        let data = results.map { [$0.frame, $0.name, $0.phone, $0.phoneState, $0.policy, $0.policyValue, $0.model, $0.soldDate, $0.verdict, $0.reason] }
        writeCSV(m, header: header, data: data)

        let ok = results.filter { $0.verdict == Verdict.ok }.count
        let bad = results.filter { $0.verdict == Verdict.notOK }.count
        let err = results.filter { $0.verdict == Verdict.lookupError }.count
        notes[m] = (stopped ? "Đã dừng. " : "Hoàn tất. ") + "Đủ tiêu chuẩn: \(ok) · Không đủ: \(bad) · Lỗi tra cứu: \(err)."
    }

    // MARK: Chạy các chế độ ghi (vòng lặp chung)

    private func runWrites(
        mode m: Mode,
        keys: [String],
        subs: [String],
        process: (Int, ApiSession, EmployeeCache, @escaping (String) -> Void, @escaping (String) -> Void) async throws -> StepResult
    ) async -> (results: [ItemResult], stopped: Bool) {
        rows[m] = zip(keys, subs).map { Row(key: $0.0, sub: $0.1, state: .waiting) }
        let session = ApiSession()
        let cache = EmployeeCache()
        var results = [ItemResult](repeating: ItemResult.pending(), count: keys.count)
        var lastEnd: Date? = nil
        var stopped = false
        let g = gap(m)
        let logFn: (String) -> Void = { s in self.addLog(s) }

        for i in 0..<keys.count {
            if stop.isSet { stopped = true; break }
            let statusFn: (String) -> Void = { s in
                self.addLog(s)
                self.setRowStatus(m, i, s)
            }
            do {
                try await CommonFlow.waitGap(seconds: g, since: lastEnd, stop: stop, label: keys[i], say: { s in self.setRowStatus(m, i, s) })
            } catch {
                stopped = true
                break
            }
            if stop.isSet { stopped = true; break }
            setRowStatus(m, i, "Đang xử lý...")
            let step: StepResult
            do {
                step = try await process(i, session, cache, logFn, statusFn)
            } catch {
                if let r = error as? RunError, case .stopped = r {
                    stopped = true
                    setRowDone(m, i, ResultRow(kind: .warn, verdict: "Đã dừng", reason: "Người dùng bấm dừng - kiểm tra tay mục này", orderNo: ""))
                    break
                }
                step = StepResult(result: ItemResult.failed("Lỗi không lường trước: \(errText(error))"), stopAll: false)
            }
            lastEnd = Date()
            results[i] = step.result
            setRowDone(m, i, ResultRow.from(step.result))
            let kq = step.result.status.text
            let lyDo = step.result.reason.isEmpty ? "" : " - \(step.result.reason)"
            let don = step.result.orderNo.isEmpty ? "" : " (Đơn hàng \(step.result.orderNo))"
            addLog("\(keys[i]): \(kq)\(don)\(lyDo)")
            if step.stopAll {
                addLog("[API] Dừng cả đợt (không lấy được token). Các mục còn lại chưa xử lý.")
                break
            }
        }
        await session.close()
        finalizeWaiting(m, reason: stopped ? "Đã dừng trước khi tới mục này" : "Chưa xử lý")
        return (results, stopped)
    }

    private func summary(_ results: [ItemResult], stopped: Bool) -> String {
        let ok = results.filter { $0.status == .success }.count
        let skip = results.filter { $0.status == .failed && $0.skipped }.count
        let bad = results.filter { $0.status == .failed && !$0.skipped }.count
        let left = results.filter { $0.status == .pending }.count
        var s = stopped ? "Đã dừng. " : "Hoàn tất. "
        s += "Thành công: \(ok) · Thất bại: \(bad) · Bỏ qua: \(skip)"
        if left > 0 { s += " · Chưa xử lý: \(left)" }
        return s
    }

    private func rememberOrders(_ results: [ItemResult]) {
        var seen = Set<String>()
        var list: [String] = []
        for r in results where r.status == .success && !r.orderNo.isEmpty {
            if seen.insert(r.orderNo).inserted { list.append(r.orderNo) }
        }
        if !list.isEmpty {
            lastOrders = list
            ud.set(list, forKey: "lastOrders")
        }
    }

    // MARK: Sửa chữa

    private func runRepair(_ items: [RepairItem]) async {
        let m = Mode.repair
        let out = await runWrites(mode: m, keys: items.map { $0.frame }, subs: items.map { $0.tech }) { i, session, cache, log, status in
            var it = items[i]
            return try await RepairFlow.one(session, cache, &it, stop: self.stop, log: log, status: status)
        }
        rememberOrders(out.results)
        let header = ["Số khung", "KTV", "Mã Công Việc", "Số Tiền", "Trạng thái", "Lý do / Ghi chú", "Số Đơn hàng"]
        var data: [[String]] = []
        for (i, it) in items.enumerated() {
            let r = out.results[i]
            data.append([it.frame, it.tech, it.jobCode, it.amount, r.status.text, r.reason, r.orderNo])
        }
        writeCSV(m, header: header, data: data)
        notes[m] = summary(out.results, stopped: out.stopped)
    }

    // MARK: Nhập liệu BT

    private func runMaintenance(_ items: [MaintItem]) async {
        let m = Mode.maintenance
        let out = await runWrites(mode: m, keys: items.map { $0.frame }, subs: items.map { $0.tech }) { i, session, cache, log, status in
            var it = items[i]
            return try await MaintFlow.one(session, cache, &it, stop: self.stop, log: log, status: status)
        }
        rememberOrders(out.results)
        let header = ["Số khung", "KTV", "Phụ tùng", "Trạng thái", "Lý do / Ghi chú", "Số Đơn hàng"]
        var data: [[String]] = []
        for (i, it) in items.enumerated() {
            let r = out.results[i]
            data.append([it.frame, it.tech, it.part, r.status.text, r.reason, r.orderNo])
        }
        writeCSV(m, header: header, data: data)
        notes[m] = summary(out.results, stopped: out.stopped)
    }

    // MARK: Kết thúc

    private func runSettle(_ orders: [String]) async {
        let m = Mode.settle
        let out = await runWrites(mode: m, keys: orders, subs: orders.map { _ in "" }) { i, session, cache, log, status in
            return try await SettleFlow.one(session, orders[i], stop: self.stop, log: log, status: status)
        }
        let header = ["Số Đơn hàng", "Trạng thái", "Lý do"]
        var data: [[String]] = []
        for (i, o) in orders.enumerated() {
            let r = out.results[i]
            data.append([o, r.status.text, r.reason])
        }
        writeCSV(m, header: header, data: data)
        notes[m] = summary(out.results, stopped: out.stopped)
    }

    // MARK: Xuất CSV

    private func q(_ s: String) -> String {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func writeCSV(_ m: Mode, header: [String], data: [[String]]) {
        var out = "\u{FEFF}" + header.map { q($0) }.joined(separator: ",") + "\n"
        for r in data { out += r.map { q($0) }.joined(separator: ",") + "\n" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(m.csvPrefix)_\(f.string(from: Date())).csv")
        do {
            try out.write(to: url, atomically: true, encoding: .utf8)
            exportURL[m] = url
        } catch {
            addLog("Không ghi được file CSV: \(error.localizedDescription)")
        }
    }
}
