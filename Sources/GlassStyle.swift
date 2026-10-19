import SwiftUI

// Use the system optical material on iOS 26+. Keep older iPhones supported.
private struct SatelliteGlass<Surface: InsettableShape>: ViewModifier {
    var shape: Surface
    var clear: Bool
    var interactive: Bool
    var tint: Color?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(uiColor: .secondarySystemBackground), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5).allowsHitTesting(false))
        } else if #available(iOS 26.0, *) {
            // Clear glass lets the Earth illuminate the large floating panels.
            // The scrim preserves text contrast over bright cities and coastlines.
            content
                .background(.black.opacity(clear ? 0.24 : 0), in: shape)
                .glassEffect((clear && contrast != .increased ? Glass.clear : Glass.regular)
                    .tint(tint).interactive(interactive), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(.black.opacity(0.12), in: shape)
                .overlay(shape.strokeBorder(LinearGradient(
                    colors: [.white.opacity(0.38), .white.opacity(0.07), .white.opacity(0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6).allowsHitTesting(false))
        }
    }
}

extension View {
    func satelliteGlass<S: InsettableShape>(in shape: S, clear: Bool = false,
                                           interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(SatelliteGlass(shape: shape, clear: clear, interactive: interactive, tint: tint))
    }
}

struct SatelliteGlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { content }
        } else {
            content
        }
    }
}

struct GlassPanel<Content: View>: View {
    var interactive = false
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .satelliteGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                            clear: true, interactive: interactive)
    }
}

struct GlassMenuIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 23, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(LinearGradient(colors: [color, color.opacity(0.65)],
                startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.42), .clear, .white.opacity(0.10)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6))
            .shadow(color: color.opacity(0.12), radius: 8, y: 3)
            .accessibilityHidden(true)
    }
}
