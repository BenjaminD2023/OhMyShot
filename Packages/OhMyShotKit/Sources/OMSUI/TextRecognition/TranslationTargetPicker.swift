import Foundation
import OMSOCR
import SwiftUI

/// The languages text can be translated into, Automatic first: Settings › Text's Translate into, and the menu of the
/// Recognized Text window's toolbar. A choice is a language's identifier ("zh-Hans"), empty for Automatic, as
/// `SettingsStore.translationTarget` keeps it; the chosen one is listed even before the languages have loaded, so the
/// picker never shows a choice it does not have.
struct TranslationTargetPicker<Automatic: View, Title: View>: View {
    @Binding var selection: String
    /// The languages there are to translate into (`Translator.targets()`), empty until they have loaded.
    let targets: [Locale.Language]
    /// Automatic's entry: the window names the language it chose.
    @ViewBuilder let automatic: () -> Automatic
    @ViewBuilder let label: () -> Title

    var body: some View {
        Picker(selection: $selection) {
            automatic().tag("")
            Divider()
            ForEach(options, id: \.self) { identifier in
                Text(verbatim: Translator.name(of: Locale.Language(identifier: identifier))).tag(identifier)
            }
        } label: {
            label()
        }
    }

    private var options: [String] {
        var options = targets.map(Translator.identifier(of:))
        if !selection.isEmpty, !options.contains(selection) { options.insert(selection, at: 0) }
        return options
    }
}
