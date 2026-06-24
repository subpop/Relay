// Copyright 2026 Link Dupont
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import NaturalLanguage
import Translation

/// Source-language detection + readable-language heuristics for the
/// per-message translation feature. Does **not** drive translation
/// itself — that's done in the SwiftUI layer via `.translationTask`,
/// which is the only public entry point that handles the system
/// download prompt for missing language models.
///
/// Responsibilities:
///
/// - Detect the dominant language of a message body
///   (`NLLanguageRecognizer`, on-device).
/// - Build a "readable languages" set from the user's preferred
///   languages + every enabled keyboard input source so we can skip
///   translation when the source is something the user already reads.
/// - Convert detected source language to a normalised
///   `Locale.Language` for handoff to `TranslationSession.Configuration`.
@MainActor
public final class MessageTranslator {
    /// The user's locale; the default translation target.
    public let targetLanguage: Locale.Language

    /// Languages the user can already read on this Mac, derived from
    /// `Locale.preferredLanguages` + enabled keyboard input sources.
    public private(set) var readableLanguages: Set<Locale.Language>

    public init(targetLocale: Locale = .current) {
        // Strip the region. Apple's Translation framework supports a
        // fixed set of base languages (en, fr, de, es, ja…); region
        // variants like `en-CA` or `fr-FR` sometimes resolve and
        // sometimes don't. Passing the bare languageCode avoids the
        // gamble — `en-CA` → `en` always works because the framework
        // ships an `en` model.
        let base: Locale.Language
        if let code = targetLocale.language.languageCode {
            base = Locale.Language(languageCode: code)
        } else {
            base = targetLocale.language
        }
        self.targetLanguage = base
        self.readableLanguages = Self.computeReadableLanguages(target: base)
    }

    public func refreshReadableLanguages() {
        readableLanguages = Self.computeReadableLanguages(target: targetLanguage)
    }

    public enum DetectionError: Swift.Error, LocalizedError {
        case empty
        case undetectable
        case alreadyReadable(Locale.Language)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Message body was empty."
            case .undetectable:
                return "Couldn't detect the message's language."
            case .alreadyReadable(let lang):
                return "Already in a language you read (\(lang.minimalIdentifier))."
            }
        }
    }

    /// Decides whether `text` warrants a translation request. If yes,
    /// returns the detected source language; otherwise throws an
    /// explanatory `DetectionError`. Caller plugs the result into a
    /// `TranslationSession.Configuration`.
    public func detectSourceLanguage(in text: String) throws -> Locale.Language {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DetectionError.empty
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let dominant = recognizer.dominantLanguage else {
            throw DetectionError.undetectable
        }

        let language = Locale.Language(identifier: dominant.rawValue)
        if readableLanguages.contains(where: { $0.minimalIdentifier == language.minimalIdentifier }) {
            throw DetectionError.alreadyReadable(language)
        }
        return language
    }

    // MARK: - Readable-language computation

    /// The user's "readable" set. We deliberately keep this minimal —
    /// just the current locale's language. Earlier versions also pulled
    /// in `Locale.preferredLanguages` and every enabled keyboard input
    /// source's claimed languages, but a single Latin-script keyboard
    /// can advertise dozens of minor European languages it loosely
    /// supports (German, Catalan, Swiss German, Basque, Sámi variants…),
    /// which made the recogniser's `de` detection collide with the set
    /// and silently skip translation. Sticking to `Locale.current` keeps
    /// the heuristic honest: only the language the user has clearly
    /// chosen for system text is treated as already-readable.
    nonisolated private static func computeReadableLanguages(target: Locale.Language) -> Set<Locale.Language> {
        [target]
    }
}
