import AppKit
import AnchorUtilities
import SwiftUI

/// Anchor's dark material system. Small surfaces use shaded fills rather than
/// independent backdrop filters, so scrolling does not blur the window once per card.
enum AnchorDesign {
    static let canvas = Color(red: 0.065, green: 0.067, blue: 0.072)
    static let surface = Color(red: 0.118, green: 0.122, blue: 0.130)
    static let raised = Color(red: 0.164, green: 0.169, blue: 0.180)
    static let inset = Color(red: 0.082, green: 0.086, blue: 0.094)
    static let accent = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let text = Color(red: 0.95, green: 0.96, blue: 0.98)
    static let muted = Color(red: 0.69, green: 0.71, blue: 0.75)
    static let edge = Color.white.opacity(0.10)
    static let radius: CGFloat = 22
}

struct AnchorCanvas: View {
    var body: some View {
        LinearGradient(colors: [AnchorDesign.surface, AnchorDesign.canvas, AnchorDesign.canvas],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .top) {
                Rectangle().fill(LinearGradient(colors: [AnchorDesign.accent.opacity(0.055), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(height: 220)
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct AnchorSurface: View {
    enum Depth { case glass, raised, inset }
    var depth: Depth = .glass
    var radius: CGFloat = AnchorDesign.radius
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: ConcentricRectangle { AnchorCorners.rectangle(cornerRadius: radius) }
    var body: some View {
        // Shadow only the simple shape, never the composite of a material,
        // gradient and border. Raised controls get their depth from the edge
        // lighting instead of two blurred shadows per button and text field.
        shape
            .fill(depth == .inset ? AnchorDesign.inset : depth == .raised ? AnchorDesign.raised : AnchorDesign.surface)
            .shadow(color: .black.opacity(depth == .glass ? 0.22 : 0), radius: depth == .glass ? 6 : 0, x: 0, y: depth == .glass ? 3 : 0)
            .overlay {
                shape.fill(LinearGradient(colors: [.white.opacity(depth == .inset ? 0.012 : 0.045), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                shape.anchorStrokeBorder(LinearGradient(colors: [.white.opacity(contrast == .increased ? 0.5 : 0.15), .white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: contrast == .increased ? 1.5 : 1)
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct AnchorButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(configuration.role == .destructive ? Color(red: 1, green: 0.52, blue: 0.55) : prominent ? AnchorDesign.canvas : AnchorDesign.text)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background {
                if prominent {
                    AnchorCorners.rectangle(cornerRadius: 11).fill(AnchorDesign.accent.opacity(configuration.isPressed ? 0.75 : 1))
                        .shadow(color: AnchorDesign.accent.opacity(0.15), radius: 8, y: 3)
                } else { AnchorSurface(depth: configuration.isPressed ? .inset : .raised, radius: 11) }
            }
            .contentShape(AnchorCorners.rectangle(cornerRadius: 11))
            .opacity(enabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
    }
}

struct AnchorToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 18) {
                configuration.label.foregroundStyle(AnchorDesign.text)
                Spacer(minLength: 12)
                Capsule().fill(configuration.isOn ? Color.blue : AnchorDesign.inset)
                    .frame(width: 38, height: 22)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.13)))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(Color.white)
                            .frame(width: 16, height: 16).padding(3)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.42)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isOn)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct AnchorFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).padding(.horizontal, 11).padding(.vertical, 9)
            .background(AnchorSurface(depth: .inset, radius: 10))
    }
}

struct AnchorGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            configuration.label.font(.headline).foregroundStyle(AnchorDesign.text)
            configuration.content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(AnchorSurface())
            .anchorCornerContainer(radius: AnchorDesign.radius)
    }
}

extension ContainerValues {
    @Entry var anchorSettingsID: String? = nil
}

/// Rebuilds existing Form sections as glass cards while retaining their controls and identities.
struct AnchorFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            // Eager sections register offscreen row anchors with ScrollViewReader.
            VStack(alignment: .leading, spacing: 22) {
                ForEach(sections: configuration.content) { section in
                    AnchorFormSection(section: section)
                }
            }.padding(24)
        }.scrollContentBackground(.hidden)
    }
}

private struct AnchorFormSection: View {
    let section: SectionConfiguration
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !section.header.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(section.header) { header in header }
                }.font(.system(size: 12, weight: .semibold)).foregroundStyle(AnchorDesign.muted)
                    .padding(.leading, 4).textCase(nil)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(section.content.enumerated()), id: \.element.id) { index, row in
                    row.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.vertical, 13)
                        .id(row.containerValues.anchorSettingsID.map { AnyHashable($0) } ?? AnyHashable(row.id))
                    if index < section.content.count - 1 {
                        Rectangle().fill(AnchorDesign.edge).frame(height: 1).padding(.horizontal, 18)
                    }
                }
            }.background(AnchorSurface(radius: 17))
            .anchorCornerContainer(radius: 17)
            if !section.footer.isEmpty {
                VStack(alignment: .leading, spacing: 4) { ForEach(section.footer) { footer in footer } }
                    .font(.system(size: 11)).foregroundStyle(AnchorDesign.muted).padding(.horizontal, 4)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AnchorThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.preferredColorScheme(.dark).environment(\.colorScheme, .dark)
            .tint(AnchorDesign.accent).accentColor(AnchorDesign.accent)
            .foregroundStyle(AnchorDesign.text)
            .buttonStyle(AnchorButtonStyle()).toggleStyle(AnchorToggleStyle())
            .textFieldStyle(AnchorFieldStyle()).groupBoxStyle(AnchorGroupBoxStyle())
    }
}

extension View {
    func anchorTheme() -> some View { modifier(AnchorThemeModifier()) }
    func anchorCard(_ depth: AnchorSurface.Depth = .glass, radius: CGFloat = AnchorDesign.radius) -> some View {
        background(AnchorSurface(depth: depth, radius: radius))
            .anchorCornerContainer(radius: radius)
    }
}

struct AnchorPageHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 21, weight: .medium))
                .foregroundStyle(AnchorDesign.accent).frame(width: 50, height: 50)
                .background(AnchorSurface(depth: .raised, radius: 15))
                .anchorCornerContainer(radius: 15)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(AnchorDesign.muted)
            }
            Spacer(minLength: 0)
        }
    }
}
