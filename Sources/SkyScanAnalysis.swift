import Foundation

enum SkyScanEnvironment: String, CaseIterable, Identifiable {
    case automatic, outdoors, indoors
    var id: String { rawValue }
    var title: String {
        switch self { case .automatic: return "Авто"; case .outdoors: return "На улице"; case .indoors: return "В помещении" }
    }
}

/// A window is an optical opening, not evidence that glass passes the radio link.
/// Depth has priority: a measured nearby surface cannot be cleared by a sky prediction.
enum SkySceneFusion {
    static func state(sample: SkySceneSample, distance: Double?, depthReliable: Bool,
                      environment: SkyScanEnvironment) -> SkyCellState {
        if depthReliable, let distance, distance.isFinite, (0.2...6).contains(distance) { return .blocked }
        guard sample.confidence.isFinite else { return .observed }
        switch sample.kind {
        case .solid: return sample.confidence >= 0.72 ? .blocked:.observed
        case .window: return sample.confidence >= 0.60 ? .opening:.observed
        case .sky:
            guard sample.confidence >= 0.85 else { return .observed }
            return environment == .outdoors ? .clear:.opening
        case .unknown: return .observed
        }
    }
}

struct SkySceneEnvironmentEstimate {
    private(set) var inferred: SkyScanEnvironment = .automatic
    private var indoorFrames = 0
    private var outdoorFrames = 0
    mutating func update(indoorEvidence: Float?) {
        guard let evidence = indoorEvidence, evidence.isFinite else { return }
        // A room seen once must not become "outdoors" just because the next
        // frame looks through its window. A fresh scan resets this history.
        if evidence >= 0.12 {
            indoorFrames += 1; outdoorFrames = 0
            if indoorFrames >= 2 { inferred = .indoors }
        } else if evidence <= 0.025 {
            outdoorFrames += 1; indoorFrames = 0
            if outdoorFrames >= 3 && inferred != .indoors { inferred = .outdoors }
        } else { indoorFrames = 0; outdoorFrames = 0 }
    }
    func resolved(selection: SkyScanEnvironment) -> SkyScanEnvironment {
        selection == .automatic ? inferred:selection
    }
}

struct SkyAnalysisRay {
    let index: Int
    let rawX: Double
    let rawY: Double
    let distance: Double?
    let depthReliable: Bool
}

/// Temporal agreement prevents a single segmentation error from repainting a
/// whole ray. Timestamps come from the captured frame, not inference completion.
struct SkyAnalysisVote {
    var state: SkyCellState = .observed
    var count = 0
    var timestamp: TimeInterval = -.infinity
    mutating func accept(_ candidate: SkyCellState, at time: TimeInterval) -> Bool {
        guard time.isFinite, time > timestamp else { return false }
        guard candidate == .clear || candidate == .blocked || candidate == .opening else {
            count = 0; state = .observed; timestamp = time; return false
        }
        if time >= timestamp && time-timestamp < 0.35 { return false }
        if candidate != state || time-timestamp > 3 { count = 0 }
        state = candidate; timestamp = time; count = min(4,count+1)
        return count >= (candidate == .clear ? 3:2)
    }
}
