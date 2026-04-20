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

/// An Xcode-style capsule segmented control for the inspector tabs.
///
/// Displays icon-only buttons inside a rounded capsule container. The selected
/// tab is highlighted with an animated blue capsule behind the icon.
struct InspectorTabBar: View {
    @Binding var selection: InspectorTab
    var tabs: [InspectorTab] = InspectorTab.allCases
    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .background(.fill.quaternary, in: Capsule())
    }

    private func tabButton(_ tab: InspectorTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selection = tab
            }
        } label: {
            Image(systemName: tab.icon)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 28)
                .foregroundStyle(selection == tab ? .white : .secondary)
                .background {
                    if selection == tab {
                        Capsule()
                            .fill(.tint)
                            .matchedGeometryEffect(id: "activeTab", in: tabNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.label)
        .accessibilityLabel(tab.label)
    }
}

#Preview {
    @Previewable @State var selection: InspectorTab = .general
    VStack {
        InspectorTabBar(selection: $selection)
            .padding()
        Text(selection.label)
            .foregroundStyle(.secondary)
    }
    .frame(width: 280)
}
