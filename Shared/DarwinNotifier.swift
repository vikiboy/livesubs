import Foundation

/// Minimal wrapper over CFNotificationCenterGetDarwinNotifyCenter for signalling
/// between the app and its broadcast extension. Darwin notifications carry no payload.
final class DarwinNotifier {
    static let shared = DarwinNotifier()

    private var handlers: [String: [() -> Void]] = [:]
    private let lock = NSLock()
    private let center = CFNotificationCenterGetDarwinNotifyCenter()

    func post(_ name: String) {
        CFNotificationCenterPostNotification(center, CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Handlers are invoked on the main queue.
    func observe(_ name: String, handler: @escaping () -> Void) {
        lock.lock()
        let isFirst = handlers[name] == nil
        handlers[name, default: []].append(handler)
        lock.unlock()
        guard isFirst else { return }

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, observer, { _, observer, name, _, _ in
            guard let observer, let name else { return }
            let notifier = Unmanaged<DarwinNotifier>.fromOpaque(observer).takeUnretainedValue()
            notifier.dispatch(name.rawValue as String)
        }, name as CFString, nil, .deliverImmediately)
    }

    private func dispatch(_ name: String) {
        lock.lock()
        let list = handlers[name] ?? []
        lock.unlock()
        DispatchQueue.main.async { list.forEach { $0() } }
    }
}
