import SwiftUI
import UIKit

// The shared code names AppKit's types. On iPhone and iPad they are UIKit's, under the same names.
typealias NSImage = UIImage
typealias NSColor = UIColor
typealias NSFont = UIFont

extension Image {
    init(nsImage: UIImage) { self.init(uiImage: nsImage) }
}

extension Color {
    init(nsColor: UIColor) { self.init(uiColor: nsColor) }
}

/// What the shared code asks of the running app.
@MainActor
enum NSApp {
    static var isActive: Bool { UIApplication.shared.applicationState == .active }
}

extension UIFontDescriptor.SymbolicTraits {
    static let bold = UIFontDescriptor.SymbolicTraits.traitBold
    static let italic = UIFontDescriptor.SymbolicTraits.traitItalic
}

enum NSSound {
    static func beep() {}
}

extension UIColor {
    static var windowBackgroundColor: UIColor { .systemBackground }
}
