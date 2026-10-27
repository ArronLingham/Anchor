/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
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
import Defaults
import AnchorUtilities

public enum LiquidGlassVariant: Int, CaseIterable, Identifiable, Defaults.Serializable, Sendable {
    case v0  = 0,  v1  = 1,  v2  = 2,  v3  = 3,  v4  = 4
    case v5  = 5,  v6  = 6,  v7  = 7,  v8  = 8,  v9  = 9
    case v10 = 10, v11 = 11, v12 = 12, v13 = 13, v14 = 14
    case v15 = 15, v16 = 16, v17 = 17, v18 = 18, v19 = 19

    public var id: Int { rawValue }

    /// Preserve saved preset IDs while using only public system materials.
    public var displayName: String {
        "\(rawValue < 10 ? "Clear" : "Regular") · \(rawValue % 10)"
    }

    var nativeGlass: Glass {
        let base: Glass = rawValue < 10 ? .clear : .regular
        return base.tint(Color.white.opacity(Double(rawValue % 10) * 0.015)).interactive()
    }

    public static let supportedRange = 0...19

    public static var defaultVariant: LiquidGlassVariant { .v11 }

    public static func clamped(_ rawValue: Int) -> LiquidGlassVariant {
        let clamped = min(max(rawValue, supportedRange.lowerBound), supportedRange.upperBound)
        return LiquidGlassVariant(rawValue: clamped) ?? .defaultVariant
    }
}

/// Native SwiftUI Liquid Glass. Existing preset IDs remain readable; 0–9 use
/// Clear and 10–19 use Regular, each with ten restrained tint strengths.
/// Content stays in the parent's SwiftUI tree, preserving environment and focus.
public struct LiquidGlassBackground<Content: View>: View {
    private let content: Content
    private let cornerRadius: CGFloat
    private let variant: LiquidGlassVariant

    public init(variant: LiquidGlassVariant = .defaultVariant,
                cornerRadius: CGFloat = 10,
                @ViewBuilder content: () -> Content) {
        self.variant = variant
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content.anchorLiquidGlass(variant.nativeGlass,
            in: AnchorCorners.rectangle(cornerRadius: cornerRadius))
            .anchorCornerContainer(radius: cornerRadius)
    }
}
