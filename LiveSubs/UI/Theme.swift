import SwiftUI
import UIKit

/// Burnt-in Cinema Subtitles — the app's one visual world.
/// The screen is a dark auditorium; the only bright thing is subtitle yellow.
enum Theme {
    /// Laser-etched release-print subtitle yellow (#FFE14D).
    static let subtitle = Color(red: 1.0, green: 0.882, blue: 0.302)
    static let subtitleUI = UIColor(red: 1.0, green: 0.882, blue: 0.302, alpha: 1)
    /// The projector gate: the hairline around the frame.
    static let gate = Color(white: 0.2)
    /// Leader film stock: the control's face.
    static let leader = Color(white: 0.09)
    static let leaderLine = Color(white: 1, opacity: 0.14)
    static let stop = Color(red: 1.0, green: 0.36, blue: 0.32)
    /// Text on the black house: instructions, then quiet footnotes.
    static let secondaryText = Color(white: 0.72)
    static let tertiaryText = Color(white: 0.55)
    /// Inset-list rows on the black house.
    static let row = Color(white: 0.11)

    /// Subtitle lettering. Release-print subtitles were cut in Helvetica; it is the
    /// genuine face of this world (installed on every iPhone), used only for subtitles.
    static func subtitleFont(_ size: CGFloat) -> UIFont {
        UIFont(name: "HelveticaNeue-Bold", size: size) ?? .systemFont(ofSize: size, weight: .bold)
    }

    static func subtitle(_ style: Font.TextStyle, size: CGFloat) -> Font {
        .custom("HelveticaNeue-Bold", size: size, relativeTo: style)
    }

    /// Wide aspect of the floating frame — CinemaScope 2.39:1.
    static let frameAspect: CGFloat = 2.39
}

