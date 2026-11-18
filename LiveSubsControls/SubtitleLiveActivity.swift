import ActivityKit
import SwiftUI
import WidgetKit

private let yellow = Color(red: 1.0, green: 0.882, blue: 0.302)

private func subtitleFont(_ size: CGFloat) -> Font { .custom("HelveticaNeue-Bold", size: size) }

/// Live subtitles in the Dynamic Island and on the Lock Screen.
struct SubtitleLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SubtitleActivityAttributes.self) { context in
            // Lock Screen / banner: a strip of the cinema frame.
            LockScreenSubtitle(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(yellow)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "captions.bubble.fill").foregroundStyle(yellow)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(yellow.opacity(0.6))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        if !context.state.original.isEmpty {
                            Text(context.state.original)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Text(context.state.line.isEmpty ? "Listening…" : context.state.line)
                            .font(subtitleFont(19))
                            .foregroundStyle(context.state.isGuess ? .white.opacity(0.86) : yellow)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .truncationMode(.head)
                            .contentTransition(.opacity)
                    }
                    .frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Image(systemName: "captions.bubble.fill").foregroundStyle(yellow)
            } compactTrailing: {
                // The newest few words ride beside the camera.
                Text(IslandText.tail(context.state.line))
                    .font(subtitleFont(13))
                    .foregroundStyle(context.state.isGuess ? .white.opacity(0.86) : yellow)
                    .lineLimit(1)
                    .frame(maxWidth: 96, alignment: .trailing)
                    .contentTransition(.opacity)
            } minimal: {
                Image(systemName: "captions.bubble.fill").foregroundStyle(yellow)
            }
            .keylineTint(yellow)
        }
    }
}

private struct LockScreenSubtitle: View {
    let state: SubtitleActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(state.label)
                    .font(subtitleFont(12))
                    .foregroundStyle(yellow.opacity(0.55))
                Spacer()
                Image(systemName: "captions.bubble.fill").font(.caption).foregroundStyle(yellow.opacity(0.55))
            }
            if !state.original.isEmpty {
                Text(state.original)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(state.line.isEmpty ? "Subtitles appear here as people speak." : state.line)
                .font(subtitleFont(22))
                .foregroundStyle(state.isGuess ? .white.opacity(0.86) : yellow)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity)
                .contentTransition(.opacity)
        }
        .padding(16)
    }
}
