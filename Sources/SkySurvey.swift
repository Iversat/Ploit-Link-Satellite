import Foundation

enum SkyCellState: Int { case unknown, observed, clear, blocked, opening }

struct SkyDirection: Equatable {
    var azimuth: Double
    var elevation: Double
}

struct SkySurvey {
    static let columns = 120
    static let rows = 30
    static let azimuthStep = 360.0 / Double(columns)
    static let elevationStep = 90.0 / Double(rows)
    private static let rowAreas = (0..<rows).map { row in
        let lower = Double(row) * elevationStep * .pi / 180
        let upper = Double(row + 1) * elevationStep * .pi / 180
        return (sin(upper)-sin(lower)) / Double(columns)
    }
    private(set) var cells = Array(repeating: SkyCellState.unknown, count: SkySurvey.columns * SkySurvey.rows)
    // Coverage records camera dwell, independently of an open/blocked classification.
    private(set) var collectedCells: Set<Int> = []
    private var hits = Array(repeating: 0, count: SkySurvey.columns * SkySurvey.rows)
    private var analysisVotes = Array(repeating:SkyAnalysisVote(),count:SkySurvey.columns * SkySurvey.rows)

    var coveredCellCount: Int { collectedCells.count }
    var hasRecordedData: Bool { !collectedCells.isEmpty || cells.contains(where: { $0 != .unknown }) }
    var coverageFraction: Double {
        if collectedCells.count == cells.count { return 1 }
        // Equal angular bins have different areas near the zenith.
        // The complete hemisphere has solid angle 2π; each row contributes
        // sin(upper elevation) - sin(lower elevation), divided across columns.
        return min(1,max(0,collectedCells.reduce(0) { sum,index in
            sum + Self.rowAreas[index / Self.columns]
        }))
    }
    @discardableResult mutating func collect(_ indices: Set<Int>) -> Set<Int> {
        var added = Set<Int>()
        for index in indices where cells.indices.contains(index) {
            guard collectedCells.insert(index).inserted else { continue }
            added.insert(index)
            if cells[index] == .unknown { cells[index] = .observed }
        }
        return added
    }

    static func index(azimuth: Double, elevation: Double) -> Int? {
        guard azimuth.isFinite, elevation.isFinite, (0...90).contains(elevation) else { return nil }
        let az = (azimuth.truncatingRemainder(dividingBy:360) + 360).truncatingRemainder(dividingBy:360)
        return min(rows - 1, Int(elevation / elevationStep)) * columns + min(columns - 1,Int(az / azimuthStep))
    }
    static func direction(at index: Int) -> SkyDirection {
        .init(azimuth:(Double(index % columns)+0.5) * azimuthStep, elevation:(Double(index / columns)+0.5) * elevationStep)
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
        guard (state == .clear || state == .blocked || state == .opening), Self.index(azimuth:direction.azimuth,elevation:direction.elevation) != nil else { return }
        for index in cells.indices {
            let cell = Self.direction(at:index)
            if AimMath.separation(az1:direction.azimuth, el1:direction.elevation, az2:cell.azimuth, el2:cell.elevation) <= 12 {
                // A depth obstacle must be rescanned, never erased by a broad clear-sky mark.
                if state == .blocked || cells[index] != .blocked { cells[index] = state }
            }
        }
    }
    mutating func applyAnalysis(index: Int, state: SkyCellState, timestamp: TimeInterval) {
        guard cells.indices.contains(index) else { return }
        if cells[index] == .unknown { cells[index] = .observed }
        guard analysisVotes[index].accept(state,at:timestamp) else { return }
        if state == .blocked || cells[index] != .blocked { cells[index] = state }
    }
    mutating func restrictOpenSkyToApertures() {
        for index in cells.indices where cells[index] == .clear {
            cells[index] = .opening
            analysisVotes[index] = SkyAnalysisVote()
        }
    }
    #if DEBUG
    static func preview() -> Self {
        var result = Self()
        // Seed the synthetic fixture in one pass, independently of camera collection.
        for index in result.cells.indices {
            let direction = Self.direction(at:index)
            if direction.elevation > 25 { result.cells[index] = .clear }
            if direction.azimuth > 220 && direction.azimuth < 290 && direction.elevation < 55 {
                result.cells[index] = .blocked
            }
            if direction.azimuth > 75 && direction.azimuth < 105 && direction.elevation > 20 && direction.elevation < 42 {
                result.cells[index] = .opening
            }
        }
        result.collect(Set(result.cells.indices.filter { Self.direction(at:$0).azimuth < 180 }))
        return result
    }
    #endif
    func assessment(path: [SkyDirection]) -> SkyAssessment {
        guard !path.isEmpty else { return .init(total:0, clear:0, blocked:0) }
        var clear = 0, blocked = 0, opening = 0
        for direction in path {
            guard let index = Self.index(azimuth:direction.azimuth, elevation:direction.elevation) else { continue }
            if cells[index] == .clear { clear += 1 }
            if cells[index] == .blocked { blocked += 1 }
            if cells[index] == .opening { opening += 1 }
        }
        return .init(total:path.count, clear:clear, blocked:blocked, opening:opening)
    }
}

struct SkyAssessment {
    var total: Int
    var clear: Int
    var blocked: Int
    var opening: Int = 0
    var unknown: Int { max(0,total - clear - blocked - opening) }
    var title: String {
        if total == 0 { return "Нужен прогноз пролёта" }
        if blocked > 0 { return "На пути есть препятствия" }
        if opening > 0 { return "Есть возможный просвет" }
        if unknown > 0 { return "Обзор ещё не проверен" }
        return "Видимых препятствий не найдено"
    }
    var detail: String {
        guard total > 0 else { return "Выберите спутник с ближайшим сеансом и актуальными данными орбиты." }
        let aperture = opening > 0 ? " · просвет \(Int(Double(opening) / Double(total) * 100))%":""
        return "Открыто \(Int(Double(clear) / Double(total) * 100))% · препятствия \(Int(Double(blocked) / Double(total) * 100))%\(aperture) · не проверено \(Int(Double(unknown) / Double(total) * 100))% пути"
    }
}
