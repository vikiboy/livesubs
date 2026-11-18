import ActivityKit
import Foundation

/// Mirrors the subtitles into a Live Activity (Dynamic Island + Lock Screen).
/// Updates are throttled: iOS budgets how often an activity may change.
@MainActor
final class IslandSubtitles {
    private var activity: Activity<SubtitleActivityAttributes>?
    private var last: SubtitleActivityAttributes.ContentState?
    private var lastSentAt = Date.distantPast
    private var pending: SubtitleActivityAttributes.ContentState?
    private var flushTask: Task<Void, Never>?
    /// Finished lines get an "alert" update, which briefly expands the island
    /// (with a silent sound; iOS may still light the screen). Off by default.
    var expandOnNewLine = false

    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(label: String) {
        guard activity == nil, isAvailable else { return }
        let state = SubtitleActivityAttributes.ContentState(line: "", original: "", label: label, isGuess: false)
        do {
            activity = try Activity.request(attributes: SubtitleActivityAttributes(),
                                            content: .init(state: state, staleDate: nil),
                                            pushType: nil)
        } catch {
            print("LiveSubs island: could not start Live Activity: \(error)")
        }
        last = state
    }

    func update(line: String, original: String, label: String, isGuess: Bool) {
        guard activity != nil else { return }
        let state = SubtitleActivityAttributes.ContentState(line: line, original: original, label: label, isGuess: isGuess)
        guard state != last else { return }
        let newFinishedLine = !isGuess && line != last?.line && !line.isEmpty
        // Guesses at most ~2×/s; finished lines go out at once.
        if newFinishedLine || Date().timeIntervalSince(lastSentAt) > 0.5 {
            send(state, alert: newFinishedLine && expandOnNewLine)
        } else {
            pending = state
            flushTask?.cancel()
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let p = self.pending else { return }
                self.send(p, alert: false)
            }
        }
    }

    func end() {
        flushTask?.cancel()
        let a = activity
        activity = nil
        last = nil
        Task { await a?.end(nil, dismissalPolicy: .immediate) }
    }

    private func send(_ state: SubtitleActivityAttributes.ContentState, alert: Bool) {
        pending = nil
        last = state
        lastSentAt = Date()
        let content = ActivityContent(state: state, staleDate: nil)
        let a = activity
        Task {
            if alert {
                await a?.update(content, alertConfiguration: AlertConfiguration(
                    title: "\(state.label)", body: "\(state.line)", sound: .named("silence.caf")))
            } else {
                await a?.update(content)
            }
        }
    }
}
