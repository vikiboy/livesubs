import SwiftUI

/// The one control. Drawn as an Academy countdown leader — the circle and crosshair
/// at the head of every film reel — because its states are a leader's states:
/// a sweep that fills while the model downloads, a sweep that turns while the
/// engine loads, a lit yellow ring while subtitles run.
struct LeaderControl: View {
    enum Mode: Equatable {
        case start
        case download
        case downloading(Double)
        case loading
        case running(level: Float)
        case paused
    }

    let mode: Mode
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                face
                sweep
                ring
                if let numeral = leaderNumeral {
                    numeral
                        .foregroundStyle(Color.white.opacity(0.9))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: symbol)
                            .font(.system(size: 38, weight: .bold))
                            .symbolRenderingMode(.hierarchical)
                            .contentTransition(.symbolEffect(.replace))
                        Text(title)
                            .font(Theme.subtitle(.title3, size: 21))
                            .contentTransition(.opacity)
                    }
                    .foregroundStyle(foreground)
                }
            }
            .frame(width: 184, height: 184)
            // The leader is a fixed object; its lettering stops growing before it overflows.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .contentShape(Circle())
        }
        .buttonStyle(LeaderPress())
        .disabled(isBusy)
        .animation(.spring(duration: 0.35), value: mode)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilityValue)
        .sensoryFeedback(.impact(weight: .medium), trigger: mode == .start)
    }

    // MARK: Layers

    private var face: some View {
        ZStack {
            Circle().fill(Theme.leader)
            // Leader crosshair and inner ring.
            Rectangle().fill(Theme.leaderLine).frame(width: 1)
            Rectangle().fill(Theme.leaderLine).frame(height: 1)
            Circle().stroke(Theme.leaderLine, lineWidth: 1).padding(30)
        }
        .clipShape(Circle())
    }

    @ViewBuilder private var sweep: some View {
        switch mode {
        case .downloading(let p):
            SweepShape(fraction: p)
                .fill(Theme.subtitle.opacity(0.22))
                .animation(.linear(duration: 0.25), value: p)
        case .loading:
            if reduceMotion {
                SweepShape(fraction: 0.5).fill(Theme.subtitle.opacity(0.18))
            } else {
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    SweepShape(fraction: (t.truncatingRemainder(dividingBy: 1.4)) / 1.4)
                        .fill(Theme.subtitle.opacity(0.2))
                }
            }
        default:
            EmptyView()
        }
    }

    private var ring: some View {
        let lit: Bool = { if case .running = mode { return true }; return false }()
        let level: CGFloat = { if case .running(let l) = mode { return CGFloat(l) }; return 0 }()
        return ZStack {
            Circle().strokeBorder(lit ? Theme.subtitle : Color(white: 0.28), lineWidth: lit ? 4 : 2)
            if lit, !reduceMotion {
                // Speech level: the lit ring breathes outward with the audio.
                Circle()
                    .strokeBorder(Theme.subtitle.opacity(0.35), lineWidth: 2)
                    .scaleEffect(1.04 + level * 0.12)
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
    }

    // MARK: Content

    /// The leader's numeral: the download percentage counts up on the face. Loading
    /// has no known length, so it shows only the turning sweep, never a fake count.
    private var leaderNumeral: AnyView? {
        guard case .downloading(let p) = mode else { return nil }
        return AnyView(
            Text("\(Int(p * 100))%")
                .font(Theme.subtitle(.largeTitle, size: 56))
                .monospacedDigit()
                .contentTransition(.numericText())
        )
    }

    private var isBusy: Bool {
        if case .downloading = mode { return true }
        return mode == .loading
    }

    private var symbol: String {
        switch mode {
        case .start: "play.fill"
        case .download: "arrow.down"
        case .downloading: "arrow.down"
        case .loading: "film"
        case .running: "stop.fill"
        case .paused: "pause.fill"
        }
    }

    private var title: String {
        switch mode {
        case .start: "Start"
        case .download: "Get model"
        case .downloading(let p): "\(Int(p * 100))%"
        case .loading: "Loading"
        case .running: "Stop"
        case .paused: "Stop"
        }
    }

    private var foreground: Color {
        switch mode {
        case .running, .paused: .white
        case .loading, .downloading: Color(white: 0.75)
        default: Theme.subtitle
        }
    }

    private var accessibilityTitle: String {
        switch mode {
        case .start: "Start subtitles"
        case .download, .downloading: "Download speech model"
        case .loading: "Starting subtitles"
        case .running, .paused: "Stop subtitles"
        }
    }

    private var accessibilityValue: String {
        if case .downloading(let p) = mode { return "\(Int(p * 100)) percent" }
        return ""
    }
}

/// A pie wedge from 12 o'clock, clockwise — the leader's sweep hand.
struct SweepShape: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: c)
        p.addArc(center: c, radius: rect.width / 2, startAngle: .degrees(-90),
                 endAngle: .degrees(-90 + 360 * min(max(fraction, 0), 1)), clockwise: false)
        p.closeSubpath()
        return p
    }
}

private struct LeaderPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
