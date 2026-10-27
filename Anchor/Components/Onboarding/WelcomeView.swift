/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import SwiftUIIntrospect

struct WelcomeView: View {
    var onGetStarted: (() -> Void)? = nil
    var body: some View {
        ZStack {
            AnchorCanvas().ignoresSafeArea()
            VStack(spacing: 26) {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 46, weight: .medium)).foregroundStyle(AnchorDesign.accent)
                    .frame(width: 112, height: 112).background(AnchorSurface(depth: .raised, radius: 32))
                    .anchorCornerContainer(radius: 32)
                VStack(spacing: 10) {
                    Text("Welcome to Anchor").font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text("A calmer space for your Mac.").font(.system(size: 15)).foregroundStyle(AnchorDesign.muted)
                }
                VStack(alignment: .leading, spacing: 22) {
                    Label("Your apps, one shortcut away", systemImage: "square.grid.2x2")
                    Label("Music and controls, within reach", systemImage: "slider.horizontal.3")
                    Label("A little room to focus", systemImage: "scope")
                }.font(.system(size: 13, weight: .medium)).padding(26).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AnchorSurface())
                    .anchorCornerContainer(radius: AnchorDesign.radius)
                Button { onGetStarted?() } label: {
                    HStack { Text("Get started"); Spacer(); Image(systemName: "arrow.right") }.padding(.vertical, 3)
                }.buttonStyle(AnchorButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
                Button("Privacy policy") {
                    if let url = URL(string: "https://ebullioscopic.github.io/DynamicIsland/privacy-policy") { NSWorkspace.shared.open(url) }
                }.buttonStyle(.plain).font(.caption).foregroundStyle(AnchorDesign.muted)
            }.frame(maxWidth: 390).padding(40)
        }.anchorTheme()
    }
}

#Preview {
    WelcomeView()
}
