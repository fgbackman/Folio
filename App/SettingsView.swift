import SwiftUI

/// Font, size, theme and layout controls. Shown in the toolbar popover and in Settings.
struct ReadingSettings: View {
    var showFloat: Bool

    @AppStorage(Keys.font) private var fontName = ReaderFont.newYork.rawValue
    @AppStorage(Keys.fontSize) private var fontSize: Double = 19
    @AppStorage(Keys.theme) private var themeName = Theme.paper.rawValue
    @AppStorage(Keys.lineGap) private var lineGap: Double = 0.38
    @AppStorage(Keys.columnWidth) private var columnWidth: Double = 680
    @AppStorage(Keys.floatFontSize) private var floatFontSize: Double = 16
    @AppStorage(Keys.floatOpacity) private var floatOpacity: Double = 1.0
    @AppStorage(Keys.floatOnTop) private var floatOnTop = true
    @AppStorage(Keys.floatTheme) private var floatThemeName = ""
    @AppStorage(Keys.animateCovers) private var animateCovers = true
    @AppStorage(Keys.liveSpaceWeather) private var liveSpaceWeather = true

    var body: some View {
        Form {
            Section("Reading") {
                Picker("Font", selection: $fontName) {
                    ForEach(ReaderFont.allCases) { f in Text(f.rawValue).tag(f.rawValue) }
                }
                LabeledContent("Size") {
                    HStack {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                        Slider(value: $fontSize, in: 12...36, step: 1)
                        Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                        Text("\(Int(fontSize))").monospacedDigit().frame(width: 24)
                    }
                }
                LabeledContent("Theme") { ThemePicker(selection: $themeName) }
                LabeledContent("Line spacing") { Slider(value: $lineGap, in: 0...1) }
                LabeledContent("Column width") { Slider(value: $columnWidth, in: 460...1100) }
                Text("The quick brown fox jumps over the lazy dog — “Don’t,” she said, *softly*.")
                    .font((ReaderFont(rawValue: fontName) ?? .newYork).font(size: 15))
                    .foregroundStyle((Theme(rawValue: themeName) ?? .paper).text)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        ThemeBackground(theme: Theme(rawValue: themeName) ?? .paper)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
            }
            if showFloat {
                Section("Library") {
                    Toggle("Animate covers", isOn: $animateCovers)
                    Text("Each cover is a real constellation with tonight's Moon, planets and meteor showers, and replays of real eclipses, comets and supernovae. Hover a cover to learn what you're seeing. Covers stay still when Reduce Motion is on.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Live space weather (NOAA)", isOn: $liveSpaceWeather)
                        .onChange(of: liveSpaceWeather) { _, on in if on { SpaceWeather.shared.refresh() } }
                    Text("Aurora on polar constellations follows NOAA's planetary K-index, checked hourly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Floating book") {
                    Picker("Theme", selection: $floatThemeName) {
                        Text("Same as reader").tag("")
                        ForEach(Theme.allCases) { t in Text(t.name).tag(t.rawValue) }
                    }
                    LabeledContent("Text size") {
                        HStack {
                            Slider(value: $floatFontSize, in: 10...32, step: 1)
                            Text("\(Int(floatFontSize))").monospacedDigit().frame(width: 24)
                        }
                    }
                    LabeledContent("Page opacity") { Slider(value: $floatOpacity, in: 0.35...1) }
                    Toggle("Keep above other windows", isOn: $floatOnTop)
                    Text("Move it by its top edge, resize from the bottom-right corner, press Esc to return to the window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ThemePicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Theme.allCases) { t in
                Button { selection = t.rawValue } label: {
                    ZStack {
                        Circle().fill(t == .glass ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(t.background))
                        Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        Text("Aa").font(.system(size: 10, weight: .semibold, design: .serif)).foregroundStyle(t.text)
                    }
                    .frame(width: 28, height: 28)
                    .overlay {
                        if selection == t.rawValue {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(t.name)
            }
        }
    }
}

struct SettingsView: View {
    var body: some View {
        ReadingSettings(showFloat: true)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
    }
}
