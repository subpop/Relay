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

/// The login flow that guides users through welcome, server selection, and sign-in.
///
/// New users are introduced to Matrix in everyday language, offered a curated list of
/// homeservers to create an account on, and can sign in via an OAuth browser flow.
/// Existing users can go directly to the sign-in form with their Matrix ID and password.
struct LoginView: View {
    @State private var step: LoginStep = .welcome

    var body: some View {
        Group {
            switch step {
            case .welcome:
                WelcomePage(step: $step)
                    .transition(.push(from: .leading))
            case .pickServer:
                ServerPickerPage(step: $step)
                    .transition(.push(from: .trailing))
            case .signIn:
                SignInPage(step: $step)
                    .transition(.push(from: .trailing))
            }
        }
        .animation(.default, value: step)
    }
}

#Preview {
    LoginView()
        .frame(width: 700, height: 580)
}

#Preview("Welcome") {
    WelcomePage(step: .constant(.welcome))
        .frame(width: 700, height: 580)
}

#Preview("Server Picker") {
    ServerPickerPage(step: .constant(.pickServer))
        .frame(width: 700, height: 580)
}

#Preview("Sign In") {
    SignInPage(step: .constant(.signIn))
        .frame(width: 700, height: 580)
}
