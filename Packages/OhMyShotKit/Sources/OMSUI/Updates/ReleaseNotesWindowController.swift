import AppKit
import Foundation
import OMSCore
import OMSDesign
import SwiftUI

public final class ReleaseNotesWindowController: NSWindowController {
    public init(version: String, markdown: String, banner: NSImage? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = String(localized: "What’s New in OhMyShot", bundle: .module)
        window.minSize = NSSize(width: 540, height: 540)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ReleaseNotesView(version: version, markdown: markdown, banner: banner) { [weak self] in self?.close() })
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    /// For scripted captures: the window as it is shown, but behind the desktop picture, never in front of anyone.
    public func showBehindWallpaper() {
        guard let window else { return }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.center()
        window.orderFront(nil)
    }
    #endif
}

private struct ReleaseNotesView: View {
    let version: String
    let markdown: String
    let banner: NSImage?
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ReleaseBanner(image: banner)
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("What’s New", bundle: .module).font(.system(size: 26, weight: .semibold))
                                .accessibilityAddTraits(.isHeader)
                            Text("Version \(version)", bundle: .module).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary, in: Capsule())
                        }
                        MarkdownNotes(markdown: markdown)
                    }
                }.padding(28)
            }
            Divider()
            HStack {
                Spacer()
                Button(action: done) { Text("Let’s Go", bundle: .module).padding(.horizontal, 8) }
                    .buttonStyle(.glassProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 28).padding(.vertical, 18)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The banner over the notes: the brand mark at size. On the app icon's own ground (the Ocean fill) stand the wordmark
/// and two lines in the wordmark's ink, the same in either appearance since they stand on a picture, with the loupe
/// large and faint behind them. White type on that ground is under 3:1, so the type is ink. A bundled picture
/// replaces the ground and the loupe, and takes the type in white.
private struct ReleaseBanner: View {
    let image: NSImage?
    private static let height: CGFloat = 200

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image {
                Image(nsImage: image).resizable().scaledToFill().frame(height: Self.height).clipped()
            } else {
                LinearGradient(colors: [Color(cgColor: Theme.Brand.color(Theme.Brand.groundStart)), Color(cgColor: Theme.Brand.color(Theme.Brand.groundEnd))],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    // An overlay, so the loupe runs off the banner's edges without making the banner any taller.
                    .overlay(alignment: .trailing) {
                        Image(nsImage: .statusItemIcon(accessibilityDescription: nil) ?? NSImage())
                            .resizable().scaledToFit().frame(width: 250, height: 250)
                            .foregroundStyle(.white.opacity(0.3))
                            .offset(x: 46, y: 34)
                            .accessibilityHidden(true)
                    }
            }
            VStack(alignment: .leading, spacing: 12) {
                // The wordmark's light form is the ink one; its dark form is for a dark picture.
                Image("Wordmark", bundle: .module).resizable().scaledToFit().frame(height: 22)
                    .environment(\.colorScheme, image == nil ? .light : .dark)
                    .accessibilityLabel(Text(verbatim: "OhMyShot"))
                Text("A little more powerful.", bundle: .module).font(.system(size: 26, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Made for your next great capture.", bundle: .module).font(.system(size: 14)).opacity(0.85)
            }
            .foregroundStyle(image == nil ? Color(cgColor: Theme.Brand.color(Theme.Brand.ink)) : .white)
            .padding(28)
        }
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

/// Block layout plus Foundation's Markdown inline parser; no web content, scripts or remote assets.
private struct MarkdownNotes: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if block.hasPrefix("```") {
                    Text(block.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced)).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                } else if block == "---" {
                    Divider()
                } else if block.hasPrefix(Self.bullet) {
                    // The bullet stands in a column of its own, so a wrapped line starts under the text, not under it.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•").accessibilityHidden(true)
                        Text(ReleaseNotes.inline(String(block.dropFirst(Self.bullet.count)), referencesIn: markdown))
                            .lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 14))
                } else {
                    let heading = block.prefix(while: { $0 == "#" }).count
                    let content = heading > 0 ? String(block.dropFirst(heading)).trimmingCharacters(in: .whitespaces) : block
                    Text(ReleaseNotes.inline(content, referencesIn: markdown))
                        .font(heading > 0 ? .system(size: heading <= 2 ? 20 : 16, weight: .semibold) : .system(size: 14))
                        .lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, heading > 0 && index > 0 ? 10 : 0)
                        .accessibilityAddTraits(heading > 0 ? .isHeader : [])
                }
            }
        }.textSelection(.enabled)
    }

    /// How `blocks` marks a list item.
    private static let bullet = "• "

    private var blocks: [String] {
        var result: [String] = [], paragraph: [String] = []
        var code = false
        func flush() { if !paragraph.isEmpty { result.append(paragraph.joined(separator: "\n")); paragraph = [] } }
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                if code { paragraph.append(line); flush() } else { flush(); paragraph.append(line) }
                code.toggle()
            } else if code { paragraph.append(line) }
            else if line.hasPrefix("[") && line.contains("]: ") { continue }
            else if line.isEmpty { flush() }
            else if line.hasPrefix("#") || line.hasPrefix("- ") || line == "---" {
                flush(); result.append(line.hasPrefix("- ") ? Self.bullet + line.dropFirst(2) : line)
            } else { paragraph.append(line) }
        }
        if code { paragraph.append("```") }
        flush()
        return result
    }
}
