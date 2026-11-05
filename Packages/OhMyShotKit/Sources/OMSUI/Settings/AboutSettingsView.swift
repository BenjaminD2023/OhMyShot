import AppKit
import Foundation
import OMSCore
import SwiftUI

struct AboutSettingsView: View {
    /// The notices file in the app's Resources (App/Acknowledgments.md), or nil in a build without one.
    let acknowledgments: URL?
    @State private var readingAcknowledgments = false

    var body: some View {
        // In a scroll view like the other panes, so the toolbar above stays clear rather than drawing its own
        // grey background over a pane with nothing to scroll.
        ScrollView {
            about
                .containerRelativeFrame([.horizontal, .vertical])
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minWidth: paneWidth, maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $readingAcknowledgments) {
            if let acknowledgments {
                AcknowledgmentsSheet(url: acknowledgments) { readingAcknowledgments = false }
            }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugOpenAcknowledgments)) { _ in
            readingAcknowledgments = acknowledgments != nil
        }
        #endif
    }

    private var about: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(AppIdentity.displayName)
                .font(.title2.weight(.semibold))
            Text("Version \(Self.info("CFBundleShortVersionString") ?? "?") (\(Self.info("CFBundleVersion") ?? "?"))", bundle: .module)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Free software under the GNU General Public License v3.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            HStack(spacing: 8) {
                Link(destination: Self.repository) {
                    HStack(spacing: 4) {
                        Self.logo("GitHubMark")
                        Text("Source Code", bundle: .module)
                    }
                }
                .help(Text(verbatim: Self.repository.absoluteString))
                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Link(destination: Self.organization) {
                    HStack(spacing: 4) {
                        Self.logo("MMFoundationLogo")
                        Text(verbatim: "MMFoundation")
                    }
                }
                .help(Text(verbatim: Self.organization.absoluteString))
                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Link(destination: CommunityInvite.discord) {
                    HStack(spacing: 4) {
                        Self.logo("DiscordMark")
                        Text("Join Discord", bundle: .module)
                    }
                }
                .help(Text(verbatim: CommunityInvite.discord.absoluteString))
            }
            .font(.callout)
            .padding(.top, 2)
            if acknowledgments != nil {
                Button { readingAcknowledgments = true } label: {
                    Text("Acknowledgments…", bundle: .module)
                }
                .help(Text("The licenses of OhMyShot and of the software it’s built with", bundle: .module))
                .padding(.top, 12)
            }
        }
        .padding(28)
    }

    private static let repository = URL(string: "https://github.com/MMFoundation/ohmyshot")!
    private static let organization = URL(string: "https://mmfoundation.dev/")!

    /// A template image from OMSUI's asset catalog, drawn in the link's color beside its text.
    private static func logo(_ name: String) -> some View {
        Image(name, bundle: .module)
            .resizable()
            .scaledToFit()
            .frame(width: 13, height: 13)
            .accessibilityHidden(true)
    }

    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
