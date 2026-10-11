import AVFoundation
import SwiftUI

/// Reads the book aloud with the system's voices, a paragraph at a time, and keeps the page in step.
@MainActor
final class Narrator: NSObject, ObservableObject {
    static let shared = Narrator()

    @Published private(set) var speaking = false
    @Published private(set) var chapter = -1
    @Published private(set) var block = -1
    /// The words being spoken, in UTF-8 bytes of the block's text.
    @Published private(set) var spoken: Range<Int>?

    private let synth = AVSpeechSynthesizer()
    private var text = ""
    private var run = 0                 // rises with every start and stop, so late callbacks are ignored

    override private init() {
        super.init()
        synth.delegate = self
    }

    static var voices: [AVSpeechSynthesisVoice] {
        let lang = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    func toggle() { speaking ? stop() : start() }

    func start() {
        let model = ReaderModel.shared
        guard model.book != nil else { return }
        run += 1
        speaking = true
        speak(chapter: model.chapter, from: model.position)
    }

    func stop() {
        run += 1
        speaking = false
        spoken = nil
        chapter = -1
        block = -1
        synth.stopSpeaking(at: .immediate)
    }

    private func speak(chapter ch: Int, from first: Int) {
        let model = ReaderModel.shared
        guard speaking, let book = model.book, ch < book.chapterCount else { stop(); return }
        let blocks = book.blocks(ch)
        guard let next = blocks.dropFirst(max(0, first)).first(where: { $0.kind != .image && $0.kind != .rule && !$0.text.isEmpty }) else {
            if ch + 1 < book.chapterCount { speak(chapter: ch + 1, from: 0) } else { stop() }
            return
        }
        chapter = ch
        block = next.index
        spoken = nil
        text = next.text
        model.follow(chapter: ch, block: next.index)

        let u = AVSpeechUtterance(string: text)
        let d = UserDefaults.standard
        if let id = d.string(forKey: Keys.voice), let v = AVSpeechSynthesisVoice(identifier: id) { u.voice = v }
        let speed = d.object(forKey: Keys.voiceRate) as? Double ?? 1.0
        u.rate = Float(min(1.0, max(0.1, Double(AVSpeechUtteranceDefaultSpeechRate) * speed)))
        u.postUtteranceDelay = next.kind == .paragraph ? 0.12 : 0.35
        synth.speak(u)
    }

    private func finished(_ token: Int) {
        guard token == run, speaking else { return }
        speak(chapter: chapter, from: block + 1)
    }

    private func speaking(_ range: NSRange, _ token: Int) {
        guard token == run, let r = Range(range, in: text) else { return }
        let u = text.utf8
        let start = u.distance(from: u.startIndex, to: r.lowerBound)
        spoken = start..<(start + text[r].utf8.count)
    }
}

extension Narrator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished(self.run) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking(characterRange, self.run) }
    }
}
