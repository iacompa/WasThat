// Comic design system: first draft. Ink outlines, hard offset shadows, halftone,
// condensed black type, loot-rarity colors. Will move to App/DesignSystem in M2.
import SwiftUI

nonisolated enum Comic {
    static let ink = Color(red: 0.08, green: 0.07, blue: 0.06)
    static let paper = Color(red: 0.96, green: 0.91, blue: 0.82)
    static let night = Color(red: 0.12, green: 0.10, blue: 0.08)
    static let yellow = Color(red: 1.00, green: 0.79, blue: 0.24)
    static let rust = Color(red: 0.84, green: 0.38, blue: 0.27)

    // Loot rarity (how mysterious a sound is)
    static let common = Color(white: 0.80)
    static let uncommon = Color(red: 0.42, green: 0.85, blue: 0.40)
    static let rare = Color(red: 0.30, green: 0.66, blue: 1.00)
    static let epic = Color(red: 0.66, green: 0.42, blue: 1.00)
    static let legendary = Color(red: 1.00, green: 0.62, blue: 0.11)

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .black).width(.condensed) }
}

/// Night background with a halftone dot field that swells toward the bottom-right.
struct HalftoneBackground: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 12
            var row = 0
            var y: CGFloat = 0
            while y < size.height + step {
                var x: CGFloat = row % 2 == 0 ? 0 : step / 2
                while x < size.width + step {
                    let t = min(1, max(0, (x / size.width + y / size.height) / 2))
                    let r = 0.5 + 3.0 * t * t
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(Comic.yellow.opacity(0.07)))
                    x += step
                }
                y += step
                row += 1
            }
        }
        .background(Comic.night)
        .ignoresSafeArea()
    }
}

struct InkPanel: ViewModifier {
    var fill: Color
    var radius: CGFloat
    var shadow: CGFloat
    var line: CGFloat
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Comic.ink, lineWidth: line))
            .background(shape.fill(Comic.ink).offset(x: shadow, y: shadow))
    }
}

extension View {
    func inkPanel(fill: Color = Comic.paper, radius: CGFloat = 12, shadow: CGFloat = 6, line: CGFloat = 3) -> some View {
        modifier(InkPanel(fill: fill, radius: radius, shadow: shadow, line: line))
    }
}

struct ComicButtonStyle: ButtonStyle {
    var fill: Color = Comic.yellow
    func makeBody(configuration: Configuration) -> some View {
        ComicButtonBody(configuration: configuration, fill: fill)
    }
}

private struct ComicButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        let down = configuration.isPressed
        configuration.label
            .font(Comic.display(15))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Comic.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .inkPanel(fill: enabled ? fill : Comic.common, radius: 7, shadow: down ? 0 : 3, line: 2.5)
            .offset(x: down ? 3 : 0, y: down ? 3 : 0)
            .opacity(enabled ? 1 : 0.6)
            .animation(.easeOut(duration: 0.08), value: down)
    }
}

struct Sticker: View {
    let text: String
    var fill: Color = Comic.yellow
    var size: CGFloat = 13
    var body: some View {
        Text(text)
            .font(Comic.display(size))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(Comic.ink)
            .padding(.horizontal, size * 0.7)
            .padding(.vertical, size * 0.25)
            .inkPanel(fill: fill, radius: size * 0.5, shadow: 2, line: 2)
    }
}

struct StepBadge: View {
    let n: Int
    var body: some View {
        Text("\(n)")
            .font(Comic.display(20))
            .foregroundStyle(Comic.ink)
            .frame(width: 34, height: 34)
            .background(Circle().fill(Comic.yellow))
            .overlay(Circle().strokeBorder(Comic.ink, lineWidth: 3))
            .background(Circle().fill(Comic.ink).offset(x: 2, y: 2))
    }
}
