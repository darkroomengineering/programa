import Foundation

/// Coalesces repeated main-thread signals into one callback after a short delay.
/// Useful for notification storms where only the latest update matters.
final class NotificationBurstCoalescer {
    private let delay: TimeInterval
    private var isFlushScheduled = false
    private var pendingAction: (() -> Void)?
    private var scheduleGeneration: UInt64 = 0

    init(delay: TimeInterval = 1.0 / 30.0) {
        self.delay = max(0, delay)
    }

    func signal(_ action: @escaping () -> Void) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        pendingAction = action
        scheduleFlushIfNeeded()
    }

    var hasPendingWork: Bool {
        isFlushScheduled || pendingAction != nil
    }

    func cancel() {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        scheduleGeneration &+= 1
        isFlushScheduled = false
        pendingAction = nil
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush(generation: generation)
        }
    }

    private func flush(generation: UInt64) {
        precondition(Thread.isMainThread, "NotificationBurstCoalescer must be used on the main thread")
        guard scheduleGeneration == generation else { return }
        isFlushScheduled = false
        guard let action = pendingAction else { return }
        pendingAction = nil
        action()
        if pendingAction != nil {
            scheduleFlushIfNeeded()
        }
    }
}
