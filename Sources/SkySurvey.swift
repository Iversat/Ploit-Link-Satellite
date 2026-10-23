import Foundation

enum SkyCellState: Int { case unknown, observed, clear, blocked }

struct SkyDirection: Equatable {
    var azimuth: Double
    var elevation: Double
}

struct SkySurvey {
    static let columns = 24
    static let rows = 9
    private(set) var cells = Array(repeating: SkyCellState.unknown, count: SkySurvey.columns * SkySurvey.rows)
    private var hits = Array(repeating: 0, count: SkySurvey.columns * SkySurvey.rows)

    static func index(azimuth: Double, elevation: Double) -> Int? {
        guard azimuth.isFinite, elevation.isFinite, (0...90).contains(elevation) else { return nil }
        let az = (azimuth.truncatingRemainder(dividingBy:360) + 360).truncatingRemainder(dividingBy:360)
        return min(rows - 1, Int(elevation / 10)) * columns + Int(az / 15)
    }
    static func direction(at index: Int) -> SkyDirection {
        .init(azimuth:Double(index % columns) * 15 + 7.5, elevation:Double(index / columns) * 10 + 5)
    }
    mutating func observe(_ direction: SkyDirection, obstacleDistance: Double? = nil, highConfidence: Bool = false) {
        guard let index = Self.index(azimuth:direction.azimuth, elevation:direction.elevation) else { return }
        if cells[index] == .unknown { cells[index] = .observed }
        // Missing or distant depth is never evidence of open sky.
        if highConfidence, let distance = obstacleDistance, distance.isFinite, (0.2...6).contains(distance) {
            hits[index] += 1
            if hits[index] >= 2 { cells[index] = .blocked }
        }
    }
    mutating func mark(_ direction: SkyDirection, state: SkyCellState) {
        guard state == .clear || state == .blocked else { return }
        for index in cells.indices {
            let cell = Self.direction(at:index)
            if AimMath.separation(az1:direction.azimuth, el1:direction.elevation, az2:cell.azimuth, el2:cell.elevation) <= 12 {
                // A depth obstacle must be rescanned, never erased by a broad clear-sky mark.
                if state == .blocked || cells[index] != .blocked { cells[index] = state }
            }
        }
    }
    func assessment(path: [SkyDirection]) -> SkyAssessment {
        guard !path.isEmpty else { return .init(total:0, clear:0, blocked:0) }
        var clear = 0, blocked = 0
        for direction in path {
            guard let index = Self.index(azimuth:direction.azimuth, elevation:direction.elevation) else { continue }
            if cells[index] == .clear { clear += 1 }
            if cells[index] == .blocked { blocked += 1 }
        }
        return .init(total:path.count, clear:clear, blocked:blocked)
    }
}

struct SkyAssessment {
    var total: Int
    var clear: Int
    var blocked: Int
    var unknown: Int { max(0,total - clear - blocked) }
    var title: String {
        if total == 0 { return "Нужен прогноз пролёта" }
        if blocked > 0 { return "На пути есть препятствия" }
        if unknown > 0 { return "Обзор ещё не проверен" }
        return "Путь отмечен открытым"
    }
    var detail: String {
        guard total > 0 else { return "Выберите спутник с ближайшим сеансом и актуальными данными орбиты." }
        return "Открыто \(Int(Double(clear) / Double(total) * 100))% · препятствия \(Int(Double(blocked) / Double(total) * 100))% · не проверено \(Int(Double(unknown) / Double(total) * 100))% пути"
    }
}
