import AppKit
import CoreServices
import SwiftUI

struct LookUpTerm: Identifiable, Hashable {
    let text: String
    var id: String { text }
}

/// What the Mac's dictionary and Wikipedia say about a word or name picked out of the book.
struct LookUpView: View {
    let term: LookUpTerm
    @Environment(\.dismiss) private var dismiss
    @State private var definition: String?
    @State private var wiki: Wiki?
    @State private var asked = false

    struct Wiki { let title: String; let summary: String; let detail: String; let page: URL? }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(term.text).font(.system(size: 20, weight: .semibold, design: .serif)).lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Dictionary") {
                        if let definition {
                            Text(definition).font(.system(size: 13)).textSelection(.enabled)
                        } else {
                            Text("No entry in the dictionaries on this Mac.").foregroundStyle(.secondary)
                        }
                    }
                    section("Wikipedia") {
                        if let wiki {
                            if !wiki.detail.isEmpty { Text(wiki.detail).font(.caption).foregroundStyle(.secondary) }
                            Text(wiki.summary).font(.system(size: 13)).textSelection(.enabled)
                            if let page = wiki.page {
                                Button("Read “\(wiki.title)” on Wikipedia") { NSWorkspace.shared.open(page) }.buttonStyle(.link)
                            }
                        } else if asked {
                            Text("No article by that name.").foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 440)
        .task(id: term) {
            definition = LookUpView.define(term.text)
            wiki = await LookUpView.wikipedia(term.text)
            asked = true
        }
    }

    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
            content()
        }
    }

    static func define(_ text: String) -> String? {
        let ns = text as NSString
        guard ns.length > 0, let found = DCSCopyTextDefinition(nil, ns, CFRange(location: 0, length: ns.length)) else { return nil }
        let s = (found.takeRetainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func wikipedia(_ text: String) async -> Wiki? {
        let lang = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        let name = text.replacingOccurrences(of: " ", with: "_")
        guard let path = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(path)?redirect=true") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Folio/1.0 (macOS ereader)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = root["extract"] as? String, !summary.isEmpty else { return nil }
        let page = ((root["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
        return Wiki(title: root["title"] as? String ?? text, summary: summary,
                    detail: root["description"] as? String ?? "", page: page.flatMap(URL.init(string:)))
    }
}
