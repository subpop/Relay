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

import SwiftUI

/// A centralized error reporting service that drives the app's error alert UI.
///
/// ``ErrorReporter`` is an `@Observable` object injected into the SwiftUI environment
/// via `\.errorReporter`. Any view model or view can call ``report(_:)`` to surface an
/// error to the user. A single `.relayErrorAlert()` modifier at the top of the view
/// hierarchy observes ``currentError`` and presents a native SwiftUI alert.
@Observable
@MainActor
public final class ErrorReporter {
    /// The error currently being presented. When non-nil, the alert is shown.
    /// The alert dismissal automatically clears this value.
    public var currentError: RelayError?

    public init() {}

    /// Reports an error to be displayed to the user.
    ///
    /// If an error is already being displayed, the new error replaces it.
    ///
    /// - Parameter error: The error to present.
    public func report(_ error: RelayError) {
        currentError = error
    }
}

// MARK: - Environment Key

private struct ErrorReporterKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue = ErrorReporter()
}

/// SwiftUI environment accessor for the shared ``ErrorReporter`` instance.
public extension EnvironmentValues {
    /// The error reporter used throughout the app for centralized error display.
    var errorReporter: ErrorReporter {
        get { self[ErrorReporterKey.self] }
        set { self[ErrorReporterKey.self] = newValue }
    }
}

// MARK: - View Modifier

/// A view modifier that presents a native SwiftUI alert when a ``RelayError`` is reported.
///
/// Apply `.relayErrorAlert()` once near the top of the view hierarchy (e.g. on `ContentView`)
/// to enable centralized error display for the entire app.
private struct RelayErrorAlert: ViewModifier {
    @Environment(\.errorReporter) private var errorReporter

    func body(content: Content) -> some View {
        content.alert(
            isPresented: Binding(
                get: { errorReporter.currentError != nil },
                set: { if !$0 { errorReporter.currentError = nil } }
            ),
            error: errorReporter.currentError
        ) { _ in
            Button("OK") { errorReporter.currentError = nil }
        } message: { error in
            if let suggestion = error.recoverySuggestion {
                Text(suggestion)
            }
        }
    }
}

public extension View {
    /// Attaches the centralized error alert to this view.
    ///
    /// When an error is reported via the environment's ``ErrorReporter``, a native
    /// SwiftUI alert is presented with the error's title and recovery suggestion.
    func relayErrorAlert() -> some View {
        modifier(RelayErrorAlert())
    }
}
