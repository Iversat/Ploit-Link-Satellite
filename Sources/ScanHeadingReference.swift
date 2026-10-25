import Foundation

/// Acquisition is stricter than retention. AR tracking bridges brief compass
/// disturbances; stale or persistently invalid readings still pause map writes.
struct ScanHeadingReference {
    private var lastAccepted: Date?

    mutating func receive(accuracy: Double, trueHeading: Double, timestamp: Date, now: Date) {
        guard accuracy.isFinite, accuracy >= 0, trueHeading.isFinite,
              (0..<360).contains(trueHeading), abs(timestamp.timeIntervalSince(now)) <= 3 else { return }
        let limit = isReady(at:now) ? 30.0 : 20.0
        if accuracy <= limit { lastAccepted = timestamp }
    }

    func isReady(at now: Date) -> Bool {
        guard let lastAccepted else { return false }
        return (0...5).contains(now.timeIntervalSince(lastAccepted))
    }

    mutating func reset() { lastAccepted = nil }
}
