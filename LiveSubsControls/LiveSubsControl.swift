import AppIntents
import SwiftUI
import WidgetKit

/// Control Center / Lock Screen / Action button control: one tap turns subtitles on or off.
struct LiveSubsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "LiveSubsToggle") {
            ControlWidgetButton(action: ToggleSubtitlesIntent()) {
                Label("LiveSubs", systemImage: "captions.bubble.fill")
            }
        }
        .displayName("Live Subtitles")
        .description("Turn English subtitles on or off.")
    }
}

@main
struct LiveSubsControls: WidgetBundle {
    var body: some Widget {
        LiveSubsControl()
        SubtitleLiveActivity()
    }
}
