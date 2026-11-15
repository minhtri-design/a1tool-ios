import SwiftUI

@main
struct A1ToolApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Tạo WebView trên luồng chính ngay khi mở app.
        _ = WebSession.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
