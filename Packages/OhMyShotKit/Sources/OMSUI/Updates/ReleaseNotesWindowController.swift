import AppKit
import Foundation
import OMSCore
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
                    ZStack(alignment: .bottomLeading) {
                        LinearGradient(colors: [Color(red: 0.20, green: 0.39, blue: 0.83), Color(red: 0.12, green: 0.68, blue: 0.64)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        if let banner {
                            Image(nsImage: banner).resizable().scaledToFill().frame(height: 200).clipped()
                        } else {
                            HStack {
                                Spacer()
                                Image(systemName: "viewfinder").font(.system(size: 150, weight: .ultraLight)).rotationEffect(.degrees(-12)).offset(x: 20, y: -8)
                            }.foregroundStyle(.white.opacity(0.16))
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text("OHMYSHOT").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(3)
                            Text("A little more powerful.", bundle: .module).font(.system(size: 29, weight: .bold))
                            Text("Made for your next great capture.", bundle: .module).font(.system(size: 14)).opacity(0.85)
                        }.foregroundStyle(.white).padding(28)
                    }.frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 9) {
                        Text("What’s New", bundle: .module).font(.system(size: 28, weight: .bold))
                        HStack(spacing: 8) {
                            Text("Version \(version)", bundle: .module).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5).background(.quaternary, in: Capsule())
                            Label(String(localized: "Ready to capture", bundle: .module), systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    MarkdownNotes(markdown: markdown)
                }.padding(28)
            }
            Divider()
            HStack {
                Text("Thanks for using OhMyShot.", bundle: .module).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(action: done) { Text("Let’s Go", bundle: .module) }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 28).padding(.vertical, 18)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Block layout plus Foundation's Markdown inline parser; no web content, scripts or remote assets.
private struct MarkdownNotes: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("```") {
                    Text(block.components(separatedBy: "\n").dropFirst().dropLast().joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced)).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                } else if block == "---" {
                    Divider()
                } else {
                    let heading = block.prefix(while: { $0 == "#" }).count
                    let content = heading > 0 ? String(block.dropFirst(heading)).trimmingCharacters(in: .whitespaces) : block
                    Text(ReleaseNotes.inline(content, referencesIn: markdown))
                        .font(heading > 0 ? .system(size: heading <= 2 ? 20 : 16, weight: .semibold) : .system(size: 14))
                        .lineSpacing(6).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, heading > 0 ? 10 : 0)
                }
            }
        }.textSelection(.enabled)
    }

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
                flush(); result.append(line.hasPrefix("- ") ? "• " + line.dropFirst(2) : line)
            } else { paragraph.append(line) }
        }
        if code { paragraph.append("```") }
        flush()
        return result
    }
}
