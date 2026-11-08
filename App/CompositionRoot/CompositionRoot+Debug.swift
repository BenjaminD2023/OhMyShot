import AppKit
import Foundation
import ImageIO
import Observation
import OMSAnnotate
import OMSCapture
import OMSCore
import OMSOCR
import OMSRecording
import OMSUI
import OSLog
import UniformTypeIdentifiers

/// The URL scheme's controller, and in debug builds the hooks scripted checks reach through it.
extension CompositionRoot {

    func makeAutomationController() -> AutomationController {
        #if DEBUG
        let hooks = makeDebugHooks()
        // A Settings window of the hooks' own, which nothing else shows or lets go of, and how they capture one.
        let makeSettings = { [unowned self] () -> SettingsWindowController in
            let controller = makeSettingsWindow()
            controller.onClose = nil
            return controller
        }
        let capture = { (window: NSWindow, name: String) in await hooks.captureHiddenWindow(window, name: name) }
        let modelPackHooks = DebugModelPackHooks(center: { [unowned self] in readerPacks.center }, makeSettings: makeSettings, capture: capture)
        let aboutHooks = DebugAboutHooks(makeSettings: makeSettings, capture: capture)
        let onboardingHooks = DebugOnboardingHooks(captureWindow: capture)
        #endif
        return AutomationController(scheme: urlScheme, settings: settings) { [weak self] command in
            self?.perform(command)
        } receiveShared: { [weak self] handoff in
            self?.receiveShared(handoff)
        } debugHandler: { url in
            #if DEBUG
            if modelPackHooks.handle(url) { return true }
            if aboutHooks.handle(url) { return true }
            if onboardingHooks.handle(url) { return true }
            hooks.handle(url)
            return true
            #else
            return false
            #endif
        }
    }

    func debugMenuEntries() -> [StatusItemController.Entry] {
        #if DEBUG
        let hooks = makeDebugHooks()
        return [
            .init(title: String(localized: "Log Displays")) { hooks.logDisplays() },
            .init(title: String(localized: "Log Active Resources")) { hooks.logResources() },
            .init(title: String(localized: "Show Onboarding")) { [weak self] in self?.replayOnboarding() },
            .init(title: String(localized: "Relaunch")) { Relauncher.relaunch() },
        ]
        #else
        return []
        #endif
    }

    #if DEBUG
    private func makeDebugHooks() -> DebugHooks {
        DebugHooks(
            displays: displays,
            permissions: permissions,
            capturer: capturer,
            overlay: overlay,
            captures: captures,
            quickAccess: quickAccess,
            showSettings: { [weak self] tab in self?.showSettings(tab) },
            searchSettings: { [weak self] query in
                self?.settingsWindow?.search(query)
                // Return in the field, a moment after the typing.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    self?.settingsWindow?.debugOpenFirstResult()
                }
            },
            showOnboarding: { [weak self] step, keys in self?.showOnboarding(at: step, keys: keys) },
            showHistory: { [weak self] in self?.showHistory() },
            restoreLatestFromHistory: { [weak self] in
                guard let self, let entry = history.items().first else { return }
                Task { await self.restore(entry) }
            },
            annotateLatestFromHistory: { [weak self] in
                guard let self, let entry = history.items().first else { return }
                annotate(entry, displayID: nil)
            },
            deleteLatestFromHistory: { [weak self] in
                guard let self, let entry = history.items().first else { return }
                quickAccess.remove(entry.id)
                history.delete(entry)
                historyWindow?.reload()
            },
            setRetention: { [weak self] retention in self?.settings.historyRetention = retention },
            historyWindow: { [weak self] in self?.historyWindow?.window },
            historyCount: { [weak self] in self?.history.items().count ?? 0 },
            latestCaptureFile: { [weak self] in
                guard let self, let entry = history.items().first else { return nil }
                return history.fileURL(for: entry)
            },
            previewRetentionChange: { [weak self] retention in self?.historyWindow?.previewRetentionChange(to: retention) },
            historySearch: makeHistorySearchHooks(),
            textCapture: textCapture,
            annotations: annotations,
            pins: pins,
            colorPicker: colorPicker,
            measurer: measurer,
            recordings: recordings,
            scrolling: scrolling,
            settings: settings,
            uploads: uploads,
            desktopIcons: desktopIcons,
            removeCheckCaptures: { [weak self] in
                guard let self else { return 0 }
                let mine = history.items().filter { ["Demo", "Test"].contains($0.appName ?? "") && $0.createdAt > .now.addingTimeInterval(-4 * 3600) }
                for entry in mine {
                    quickAccess.remove(entry.id)
                    history.delete(entry)
                }
                historyWindow?.reload()
                return mine.count
            },
            perform: { [weak self] in self?.perform($0) },
            uploadAfterCapture: { [weak self] in self?.uploadAfterCapture($0) },
            pressShortcut: { [weak self] in self?.handle($0) },
            latestCaptureID: { [weak self] in self?.history.items().first?.id },
            replay: { [weak self] in self?.replayStorage },
            shortcutFormula: { [weak self] data in try await self?.shortcuts.formula(inImage: data) },
            shortcutText: { [weak self] data in try await self?.shortcuts.text(inImage: data, keepsLineBreaks: true) },
            setCloudDemo: { [weak self] store in
                self?.settingsWindow?.close()
                self?.demoCloudModels = store
            },
            addCloudDemoModel: { [weak self] model, key in
                guard let store = self?.demoCloudModels else {
                    Log.app.error("debug.cloud-local: turn the demo models on first (cloud-demo?on=1)")
                    return
                }
                store.choose(.other)
                guard var local = store.model else { return }
                local.kind = model.kind
                local.name = model.name
                local.address = model.address
                local.model = model.model
                store.update(local)
                if let key { try? store.setKey(key) }
                Log.app.notice("debug.cloud-local set \(model.name, privacy: .public) at \(model.address, privacy: .public)")
            }
        )
    }

    private func makeHistorySearchHooks() -> DebugHooks.HistorySearchHooks {
        let testApp = "OhMyShot Test"
        return DebugHooks.HistorySearchHooks(
            add: { [weak self] url in
                guard let self, let data = try? Data(contentsOf: url),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      let entry = try? history.add(
                          data: data, name: url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension,
                          kind: .screenshot, pixelWidth: width, pixelHeight: height, appName: testApp
                      )
                else { return Log.app.notice("debug.history-add failed") }
                Log.app.notice("debug.history-add \(entry.fileName, privacy: .public)")
                historyWindow?.reload()
                readTextSoon()
            },
            removeTests: { [weak self] in
                guard let self else { return }
                let tests = history.items().filter { $0.appName == testApp }
                tests.forEach(history.delete)
                historyWindow?.reload()
                Log.app.notice("debug.history-remove-tests \(tests.count, privacy: .public)")
            },
            search: { [weak self] query in
                // Counts for the whole history; names and what was found only for the test pictures.
                guard let self else { return "" }
                let items = history.items(), terms = HistorySearch.terms(in: query)
                var folding = HistorySearch.Folding()
                var found = 0, unread = 0, tests: [String] = []
                for item in items {
                    guard let text = item.kind == .screenshot ? history.text(of: item) : "" else {
                        unread += 1
                        continue
                    }
                    guard let match = HistorySearch.match(terms, in: HistorySearch.Entry(text: text, appName: item.appName, folding: &folding)) else { continue }
                    found += 1
                    if item.appName == testApp { tests.append("\(item.fileName) [\(match.excerpt.map { $0.before + "|" + $0.found + "|" + $0.after } ?? "app")]") }
                }
                return "found \(found) of \(items.count), unread \(unread); tests: \(tests.joined(separator: "; "))"
            },
            read: { [weak self] in self?.textReader.readNow() },
            reading: { [weak self] in self?.textReader.reading ?? 0 },
            setQuery: { [weak self] query in self?.historyWindow?.previewSearch(query) },
            setFilter: { [weak self] name in self?.historyWindow?.previewFilter(name) }
        )
    }
    #endif
}
