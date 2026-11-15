import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showLogin = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HeaderView(showLogin: $showLogin)
                ModeTabs()
                BannerView()
                InputCard()
                ControlCard()
                if let n = model.notes[model.mode], !n.isEmpty {
                    Text(n)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(red: 0.93, green: 0.96, blue: 1.0))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                SummaryView()
                StepCards()
                ResultsList()
                LogView()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $showLogin, onDismiss: { model.refreshLoginStatus() }) {
            LoginSheet().environmentObject(model)
        }
        .alert(
            "Xác nhận ghi dữ liệu thật",
            isPresented: Binding(get: { model.pending != nil }, set: { _ in }),
            actions: {
                Button("Bắt đầu", role: .destructive) { model.confirmPending() }
                Button("Hủy", role: .cancel) { model.cancelPending() }
            },
            message: { Text(model.pending?.message ?? "") }
        )
        .preferredColorScheme(.light)
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var model: AppModel
    @Binding var showLogin: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.blueLight, Theme.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("A1").font(.system(size: 16, weight: .heavy)).foregroundColor(.white)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("A1 Tool").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                Text(model.loginStatus).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.75)).lineLimit(2)
            }
            Spacer()
            Button { showLogin = true } label: {
                Label("Đăng nhập", systemImage: "person.badge.key")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.white.opacity(0.16))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(12)
        .background(LinearGradient(colors: [Theme.navy, Theme.navy2], startPoint: .leading, endPoint: .trailing))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Chọn chế độ

struct ModeTabs: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Mode.allCases) { m in
                Button { model.mode = m } label: {
                    VStack(spacing: 4) {
                        Image(systemName: m.symbol).font(.system(size: 18, weight: .semibold))
                        Text(m.shortTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(model.mode == m ? Theme.blue : Color.white)
                    .foregroundColor(model.mode == m ? .white : Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
                }
                .disabled(model.running != nil)
            }
        }
    }
}

struct BannerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let m = model.mode
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: m.writes ? "exclamationmark.triangle.fill" : "eye.fill")
                .foregroundColor(m.writes ? Theme.amber : Theme.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(m.title).font(.system(size: 15, weight: .bold)).foregroundColor(Theme.ink)
                Text(m.detail).font(.system(size: 13)).foregroundColor(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(m.writes ? Color(red: 1.0, green: 0.96, blue: 0.88) : Color(red: 0.90, green: 0.97, blue: 0.92))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Nhập danh sách

struct InputCard: View {
    @EnvironmentObject var model: AppModel
    @State private var showImporter = false
    @State private var showStopQty = false

    private func binding(_ m: Mode) -> Binding<String> {
        Binding(get: { model.inputs[m] ?? "" }, set: { model.inputs[m] = $0 })
    }

    var body: some View {
        let m = model.mode
        let text = binding(m)
        VStack(alignment: .leading, spacing: 10) {
            Text(m.inputTitle).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.ink)
            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if (model.inputs[m] ?? "").isEmpty {
                    Text(m.hint)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.muted.opacity(0.8))
                        .padding(.horizontal, 12).padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                SmallButton(title: "Dán", symbol: "doc.on.clipboard") {
                    if let s = UIPasteboard.general.string, !s.isEmpty {
                        let cur = model.inputs[m] ?? ""
                        model.inputs[m] = cur.isEmpty ? s : cur + "\n" + s
                    }
                }
                SmallButton(title: "Nhập file", symbol: "folder") { showImporter = true }
                SmallButton(title: "Mẫu", symbol: "text.badge.plus") { model.inputs[m] = m.sample }
                SmallButton(title: "Xóa", symbol: "trash") { model.inputs[m] = "" }
            }
            .disabled(model.running != nil)

            if m == .maintenance {
                DisclosureGroup(isExpanded: $showStopQty) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mỗi dòng: Mã phụ tùng, Số lượng dừng. Tồn kho ≤ số lượng dừng thì tool không thêm phụ tùng đó vào phiếu.")
                            .font(.system(size: 12)).foregroundColor(Theme.muted)
                        TextEditor(text: $model.stopQtyText)
                            .font(.system(size: 14, design: .monospaced))
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Theme.bg)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } label: {
                    Text("Số lượng dừng (tuỳ chọn)").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink)
                }
            }
            if m == .settle && !model.lastOrders.isEmpty {
                Button { model.useLastOrders() } label: {
                    Label("Lấy \(model.lastOrders.count) số đơn từ lần chạy Sửa chữa / Nhập BT trước", systemImage: "arrow.down.doc")
                        .font(.system(size: 14, weight: .semibold))
                }
                .disabled(model.running != nil)
            }
        }
        .cardStyle()
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data],
            allowsMultipleSelection: false
        ) { result in
            importFile(result, mode: m)
        }
    }

    private func importFile(_ result: Result<[URL], Error>, mode m: Mode) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        if url.pathExtension.lowercased() == "xlsx" || url.pathExtension.lowercased() == "xls" {
            model.notes[m] = "Chưa đọc trực tiếp file Excel. Hãy mở file, chọn các cột cần dùng, sao chép rồi bấm nút Dán (hoặc xuất ra CSV rồi nhập lại)."
            return
        }
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            model.inputs[m] = s
            model.notes[m] = ""
        } else if let s = try? String(contentsOf: url, encoding: .utf16) {
            model.inputs[m] = s
            model.notes[m] = ""
        } else {
            model.notes[m] = "Không đọc được file này (cần dạng văn bản/CSV UTF-8)."
        }
    }
}

struct SmallButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.bg)
                .foregroundColor(Theme.ink)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - Điều khiển

struct ControlCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let m = model.mode
        let gapBinding = Binding<Double>(get: { model.gap(m) }, set: { model.gaps[m] = $0 })
        VStack(alignment: .leading, spacing: 12) {
            Stepper(value: gapBinding, in: 0...120, step: 0.5) {
                Text("Giãn cách giữa các mục: \(model.gap(m), specifier: "%.1f") giây")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink)
            }
            .disabled(model.running != nil)

            HStack(spacing: 10) {
                Button { model.start() } label: {
                    HStack(spacing: 8) {
                        if model.running == m {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(model.running == m ? "Đang chạy..." : (m.writes ? "Bắt đầu (ghi thật)" : "Bắt đầu kiểm tra"))
                    }
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(model.running != nil ? Color.gray : (m.writes ? Theme.amber : Theme.blue))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(model.running != nil)

                Button { model.requestStop() } label: {
                    Label(model.stopping ? "Đang dừng..." : "Dừng ngay", systemImage: "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.vertical, 13).padding(.horizontal, 16)
                        .background(model.running == nil ? Color.gray.opacity(0.35) : Theme.red)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(model.running == nil || model.stopping)
            }

            if let url = model.exportURL[m], model.running == nil {
                ShareLink(item: url) {
                    Label("Xuất / chia sẻ file kết quả (CSV)", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .cardStyle()
    }
}

// MARK: - Tổng kết

struct SummaryView: View {
    @EnvironmentObject var model: AppModel

    private func counts(_ rows: [Row]) -> (Int, Int, Int) {
        var good = 0, bad = 0, warn = 0
        for r in rows {
            if case .done(let d) = r.state {
                switch d.kind {
                case .good: good += 1
                case .bad: bad += 1
                case .warn: warn += 1
                }
            }
        }
        return (good, bad, warn)
    }

    var body: some View {
        let m = model.mode
        let rows = model.rows[m] ?? []
        if !rows.isEmpty {
            let done = rows.filter { $0.state.isDone }.count
            let c = counts(rows)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tiến độ \(done)/\(rows.count)").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.ink)
                    Spacer()
                }
                ProgressView(value: Double(done), total: Double(max(rows.count, 1)))
                    .tint(Theme.blue)
                HStack(spacing: 8) {
                    CountPill(label: m.countLabels[0], n: c.0, color: Theme.green)
                    CountPill(label: m.countLabels[1], n: c.1, color: Theme.red)
                    CountPill(label: m.countLabels[2], n: c.2, color: Theme.amber)
                }
            }
            .cardStyle()
        }
    }
}

struct CountPill: View {
    let label: String
    let n: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.system(size: 20, weight: .heavy)).foregroundColor(color)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 3 thẻ: đã làm / hiện tại / tiếp theo

struct StepCards: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let rows = model.rows[model.mode] ?? []
        if !rows.isEmpty && model.running == model.mode {
            let lastDone = rows.lastIndex(where: { $0.state.isDone })
            let cur = rows.firstIndex(where: { $0.state.isRunning })
            let next = rows.firstIndex(where: { $0.state.isWaiting })
            VStack(spacing: 10) {
                if let i = lastDone { StepCard(title: "Vừa làm xong", row: rows[i]) }
                if let i = cur { StepCard(title: "Đang làm", row: rows[i]) }
                if let i = next { StepCard(title: "Tiếp theo", row: rows[i]) }
            }
        }
    }
}

struct StepCard: View {
    let title: String
    let row: Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).foregroundColor(Theme.muted)
            HStack {
                Text(row.key).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundColor(Theme.ink)
                if !row.sub.isEmpty {
                    Text(row.sub).font(.system(size: 13)).foregroundColor(Theme.muted)
                }
                Spacer()
                StateBadge(state: row.state)
            }
            StateDetail(state: row.state)
        }
        .cardStyle()
    }
}

struct StateBadge: View {
    let state: RowState

    var body: some View {
        switch state {
        case .waiting:
            Badge(text: "Chờ", color: Theme.muted)
        case .running:
            HStack(spacing: 6) { ProgressView().scaleEffect(0.7); Text("Đang chạy").font(.system(size: 12, weight: .bold)) }
                .foregroundColor(Theme.blue)
        case .done(let r):
            Badge(text: r.verdict, color: Theme.color(r.kind))
        }
    }
}

struct StateDetail: View {
    let state: RowState

    var body: some View {
        switch state {
        case .waiting:
            EmptyView()
        case .running(let s):
            Text(s).font(.system(size: 13)).foregroundColor(Theme.blue)
        case .done(let r):
            if !r.detail.isEmpty {
                Text(r.detail).font(.system(size: 13)).foregroundColor(Theme.color(r.kind))
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.14))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

// MARK: - Kết quả chi tiết

struct ResultsList: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded = true

    var body: some View {
        let rows = model.rows[model.mode] ?? []
        if !rows.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 0) {
                    ForEach(rows) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(r.key).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundColor(Theme.ink)
                                if !r.sub.isEmpty { Text(r.sub).font(.system(size: 12)).foregroundColor(Theme.muted) }
                                Spacer()
                                StateBadge(state: r.state)
                            }
                            StateDetail(state: r.state)
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            } label: {
                Text("Kết quả chi tiết (\(rows.count))").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.ink)
            }
            .cardStyle()
        }
    }
}

// MARK: - Nhật ký

struct LogView: View {
    @EnvironmentObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        if !model.log.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundColor(Color(red: 0.80, green: 0.90, blue: 0.80))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Color.clear.frame(height: 1).id("cuoi")
                            }
                            .padding(10)
                        }
                        .frame(height: 280)
                        .background(Color(red: 0.07, green: 0.09, blue: 0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onChange(of: model.log.count) { _ in
                            proxy.scrollTo("cuoi", anchor: .bottom)
                        }
                    }
                    Button { model.copyLog() } label: {
                        Label("Sao chép nhật ký", systemImage: "doc.on.doc").font(.system(size: 13, weight: .semibold))
                    }
                }
            } label: {
                Text("Nhật ký (\(model.log.count) dòng)").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.ink)
            }
            .cardStyle()
        }
    }
}

// MARK: - Đăng nhập

struct LoginSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCred = false

    var body: some View {
        NavigationStack {
            WebViewHost()
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("A1-Stream")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Đóng") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("Tự đăng nhập") { Task { await model.autoLogin() } }
                            Button("Tài khoản đã lưu") { showCred = true }
                            Button("Tải lại trang") { WebSession.shared.reload() }
                            Button("Về trang Job") { WebSession.shared.load(Rules.targetURL) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Text(model.loginStatus)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(Theme.navy)
                }
                .onAppear { WebSession.shared.ensureLoaded() }
                .sheet(isPresented: $showCred) { CredentialsSheet() }
        }
    }
}

struct CredentialsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var pass = ""
    @State private var totp = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Tài khoản A1-Stream"), footer: Text("Lưu trên máy này (Keychain). Khoá TOTP là chuỗi Base32 khi cài Google Authenticator; bỏ trống nếu tài khoản không bật MFA.")) {
                    TextField("Username", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Mật khẩu", text: $pass)
                    TextField("Khoá TOTP (Base32)", text: $totp)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Tài khoản đã lưu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        Credentials(username: user.trimmed, password: pass, totpSecret: totp.trimmed).save()
                        dismiss()
                    }
                }
            }
            .onAppear {
                let c = Credentials.load()
                user = c.username
                pass = c.password
                totp = c.totpSecret
            }
        }
    }
}
