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

/// The initial welcome page that introduces Relay and Matrix to new users.
///
/// Presents a hero visual, a brief explanation of the Matrix network in everyday
/// terms, and two calls to action: one for new users to pick a server, and one
/// for existing users to sign in directly.
struct WelcomePage: View {
    @Binding var step: LoginStep

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                HeroSection()
                ExplanationSection()
                ActionSection(step: $step)
            }
            .frame(maxWidth: 400)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sections

/// The hero visual with a large SF Symbol, app icon, and title.
private struct HeroSection: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Welcome to Relay")
                    .font(.largeTitle)
                    .bold()

                Text("All the power of Matrix. None of the complexity.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A brief explanation of what Matrix is in everyday language.
private struct ExplanationSection: View {
    var body: some View {
        Text(
            "Relay is powered by Matrix, an open network for secure messaging. Like email, you pick a provider and can message anyone — even people on other providers."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The primary and secondary call-to-action buttons.
private struct ActionSection: View {
    @Binding var step: LoginStep

    var body: some View {
        VStack(spacing: 12) {
            Button(action: getStarted) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: signIn) {
                Text("I Already Have an Account")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private func getStarted() {
        step = .pickServer
    }

    private func signIn() {
        step = .signIn
    }
}

// MARK: - Preview

#Preview {
    WelcomePage(step: .constant(.welcome))
        .frame(width: 700, height: 580)
}
