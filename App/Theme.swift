import AppKit
import SwiftUI

enum Keys {
    static let fontSize = "fontSize"
    static let floatFontSize = "floatFontSize"
    static let font = "fontName"
    static let theme = "theme"
    static let lineGap = "lineGap"
    static let columnWidth = "columnWidth"
    static let floatOpacity = "floatOpacity"
    static let floatOnTop = "floatOnTop"
    static let floatTheme = "floatTheme"
    static let animateCovers = "animateCovers"
    static let liveSpaceWeather = "liveSpaceWeather"
    static let tintPages = "tintPages"
    static let twoPages = "twoPages"
    static let pagedTurns = "pagedTurns"
    static let voice = "voice"
    static let voiceRate = "voiceRate"
    static let shelfOrder = "shelfOrder"
    static let syncShelf = "syncShelf"
    static let finderCovers = "finderCovers"
    static let pdfAsText = "pdfAsText"
    static let ownCovers = "ownCovers"
}

enum Theme: String, CaseIterable, Identifiable {
    case paper, sepia, sage, night, midnight, glass
    var id: String { rawValue }

    var name: String {
        switch self {
        case .paper: return "Paper"
        case .sepia: return "Sepia"
        case .sage: return "Sage"
        case .night: return "Night"
        case .midnight: return "Midnight"
        case .glass: return "Glass"
        }
    }

    var background: Color {
        switch self {
        case .paper: return Color(red: 0.992, green: 0.986, blue: 0.970)
        case .sepia: return Color(red: 0.957, green: 0.918, blue: 0.839)
        case .sage: return Color(red: 0.890, green: 0.918, blue: 0.871)
        case .night: return Color(red: 0.137, green: 0.137, blue: 0.149)
        case .midnight: return Color.black
        case .glass: return Color.clear
        }
    }

    var text: Color {
        switch self {
        case .paper: return Color(red: 0.13, green: 0.12, blue: 0.11)
        case .sepia: return Color(red: 0.29, green: 0.21, blue: 0.13)
        case .sage: return Color(red: 0.15, green: 0.20, blue: 0.16)
        case .night: return Color(red: 0.86, green: 0.85, blue: 0.81)
        case .midnight: return Color(red: 0.70, green: 0.66, blue: 0.58)
        case .glass: return Color.primary
        }
    }

    var secondary: Color { text.opacity(0.55) }
    var isDark: Bool { self == .night || self == .midnight }
    var highlight: Color { isDark ? Color.yellow.opacity(0.30) : Color.yellow.opacity(0.45) }
    var selectedHighlight: Color { Color.orange.opacity(isDark ? 0.55 : 0.60) }

    /// nil = follow the system (Glass)
    var colorScheme: ColorScheme? {
        switch self {
        case .night, .midnight: return .dark
        case .glass: return nil
        default: return .light
        }
    }
}

enum ReaderFont: String, CaseIterable, Identifiable {
    case newYork = "New York"
    case sanFrancisco = "San Francisco"
    case iowan = "Iowan Old Style"
    case charter = "Charter"
    case palatino = "Palatino"
    case georgia = "Georgia"
    case baskerville = "Baskerville"
    case avenir = "Avenir Next"
    case menlo = "Menlo"
    var id: String { rawValue }

    func font(size: CGFloat) -> Font {
        switch self {
        case .newYork: return .system(size: size, design: .serif)
        case .sanFrancisco: return .system(size: size)
        default: return .custom(rawValue, size: size)
        }
    }
}

/// Paints a theme's page: a flat color, or real behind-window blur for Glass.
struct ThemeBackground: View {
    let theme: Theme
    var body: some View {
        if theme == .glass { VisualEffectView() } else { theme.background }
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

extension View {
    @ViewBuilder func colorSchemeOverride(_ scheme: ColorScheme?) -> some View {
        if let scheme { self.environment(\.colorScheme, scheme) } else { self }
    }
}

/// Small helper: hands back the NSWindow hosting a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
    }
}
