import SwiftUI

enum Theme {
    static let bg = Color(red: 0.94, green: 0.95, blue: 0.97)
    static let navy = Color(red: 0.06, green: 0.12, blue: 0.25)
    static let navy2 = Color(red: 0.10, green: 0.20, blue: 0.40)
    static let blue = Color(red: 0.11, green: 0.35, blue: 0.85)
    static let blueLight = Color(red: 0.30, green: 0.55, blue: 0.98)
    static let green = Color(red: 0.09, green: 0.60, blue: 0.34)
    static let red = Color(red: 0.84, green: 0.22, blue: 0.22)
    static let amber = Color(red: 0.85, green: 0.52, blue: 0.04)
    static let ink = Color(red: 0.10, green: 0.13, blue: 0.20)
    static let muted = Color(red: 0.42, green: 0.46, blue: 0.54)
    static let line = Color(red: 0.88, green: 0.90, blue: 0.93)

    static func color(_ k: RowKind) -> Color {
        switch k {
        case .good: return green
        case .bad: return red
        case .warn: return amber
        }
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}

extension RowState {
    var isDone: Bool { if case .done = self { return true } else { return false } }
    var isRunning: Bool { if case .running = self { return true } else { return false } }
    var isWaiting: Bool { if case .waiting = self { return true } else { return false } }
}
