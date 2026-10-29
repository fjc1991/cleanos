import SwiftUI

/// Colour tokens and reusable styles. The originals use a deep blue/violet gradient in dark mode and a
/// light slate gradient in light mode; everything else is system material so it stays native.
enum Theme {
    static let accent = Color(red: 0.36, green: 0.55, blue: 1.0)
    static let accentSecondary = Color(red: 0.62, green: 0.40, blue: 0.95)
    static let success = Color(red: 0.30, green: 0.80, blue: 0.55)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.25)
    static let danger = Color(red: 0.95, green: 0.35, blue: 0.40)

    static let cornerRadius: CGFloat = 14

    /// Window background gradient, resolved for the current colour scheme.
    static func backgroundGradient(for scheme: ColorScheme) -> LinearGradient {
        let colors: [Color] = scheme == .dark
            ? [Color(red: 0.07, green: 0.09, blue: 0.20), Color(red: 0.11, green: 0.10, blue: 0.30), Color(red: 0.05, green: 0.06, blue: 0.16)]
            : [Color(red: 0.93, green: 0.95, blue: 1.0), Color(red: 0.90, green: 0.90, blue: 0.98), Color(red: 0.96, green: 0.97, blue: 1.0)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Category colours for the disk-usage bar (Other volumes, System, Applications, …).
    static let categoryPalette: [Color] = [
        Color(red: 0.25, green: 0.60, blue: 1.00),
        Color(red: 0.95, green: 0.40, blue: 0.45),
        Color(red: 0.98, green: 0.60, blue: 0.25),
        Color(red: 0.60, green: 0.45, blue: 0.95),
        Color(red: 0.95, green: 0.85, blue: 0.30),
        Color(red: 0.30, green: 0.80, blue: 0.70),
        Color(red: 0.90, green: 0.45, blue: 0.80),
        Color(red: 0.40, green: 0.75, blue: 0.95),
        Color(red: 0.55, green: 0.80, blue: 0.40),
    ]
}

/// A translucent rounded card, used for every panel inside a section.
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// The primary call-to-action button at the bottom of every section ("Review and Clean Up").
struct PrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accentSecondary], startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Color.gray.opacity(0.35)))
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// Appearance preference stored in settings.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
