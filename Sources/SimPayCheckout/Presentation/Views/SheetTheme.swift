#if os(iOS)
import SwiftUI
import UIKit

/// Colours of the sheet. Brand values come from `SheetStyle` of the Android SDK; every
/// colour has a dark variant, and text uses system colours so contrast follows the
/// platform settings (including Increase Contrast).
enum SheetTheme {

    /// SimPay green (`#00D150`).
    static let accent = Color(uiColor: UIColor(hex: 0x00D150))
    /// Text on the green button. Dark text keeps a contrast ratio above 7:1; white text
    /// on this green would be below the WCAG minimum.
    static let onAccent = Color(uiColor: UIColor(hex: 0x05210F))
    static let accentDisabled = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x1F3A28) : UIColor(hex: 0xA8E9C1) })
    /// Text on the disabled button; stays readable (about 6:1) in both appearances.
    static let onAccentDisabled = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xB5C4BA) : UIColor(hex: 0x1D4D2F) })
    static let highlight = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x10301D) : UIColor(hex: 0xE9FBF0) })
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let border = Color(uiColor: .separator)
    static let danger = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xF97066) : UIColor(hex: 0xD92D20) })
    static let success = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x32D583) : UIColor(hex: 0x039855) })
    static let pending = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xFDB022) : UIColor(hex: 0xB54708) })

    /// Secondary text. Darker than the system `.secondary` so captions keep a contrast
    /// ratio of at least 7:1 on the sheet surfaces (the accessibility audit flagged it).
    static let secondaryText = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0xD0D5DD) : UIColor(hex: 0x475467) })

    /// SimPay green for text on white (contrast above 5:1); the brand green is for fills.
    static let accentText = Color(uiColor: UIColor(hex: 0x027A48))

    static let cornerRadius: CGFloat = 16
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The three bars of the SimPay mark, taken from `SimPayLoaderView` of the Android SDK
/// (artwork coordinates 40.18...74.8 × 39.6...71.07). Drawn as a shape: no bundled or
/// downloaded image.
struct SimPayMark: Shape {

    private static let bounds = CGRect(x: 40.18, y: 39.6, width: 34.62, height: 31.47)

    func path(in rect: CGRect) -> Path {
        var artwork = Path()
        artwork.move(to: CGPoint(x: 74.8, y: 48.74))
        artwork.addLine(to: CGPoint(x: 40.18, y: 48.74))
        artwork.addCurve(to: CGPoint(x: 50.05, y: 39.6), control1: CGPoint(x: 40.18, y: 43.65), control2: CGPoint(x: 44.55, y: 39.6))
        artwork.addLine(to: CGPoint(x: 74.8, y: 39.6))
        artwork.closeSubpath()

        artwork.addRect(CGRect(x: 40.18, y: 50.82, width: 34.62, height: 9.18))

        artwork.move(to: CGPoint(x: 64.93, y: 71.07))
        artwork.addLine(to: CGPoint(x: 40.18, y: 71.07))
        artwork.addLine(to: CGPoint(x: 40.18, y: 61.92))
        artwork.addLine(to: CGPoint(x: 74.8, y: 61.92))
        artwork.addCurve(to: CGPoint(x: 64.93, y: 71.07), control1: CGPoint(x: 74.8, y: 67.02), control2: CGPoint(x: 70.43, y: 71.07))
        artwork.closeSubpath()

        let bounds = Self.bounds
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        let x = rect.midX - bounds.width * scale / 2
        let y = rect.midY - bounds.height * scale / 2
        let transform = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x, y: y))
        return artwork.applying(transform)
    }
}

/// Mark and wordmark, read by VoiceOver as "SimPay".
struct SimPayBrand: View {
    let strings: SheetStrings
    @ScaledMetric(relativeTo: .headline) private var markHeight: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            SimPayMark()
                .fill(SheetTheme.accent)
                .frame(width: markHeight * 1.1, height: markHeight)
            Text(verbatim: "SimPay")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings.text("a11y.simpay"))
    }
}

/// Full width primary button in SimPay green.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .foregroundStyle(isEnabled ? SheetTheme.onAccent : SheetTheme.onAccentDisabled)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isEnabled ? SheetTheme.accent : SheetTheme.accentDisabled)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

/// Full width secondary button.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(SheetTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(SheetTheme.border)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}
#endif
