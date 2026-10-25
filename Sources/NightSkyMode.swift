import Foundation

enum NightSkyMode: String, CaseIterable, Identifiable {
    case explore, gyroscope, augmented
    var id: Self { self }
    var title: String {
        switch self {
        case .explore: return "Обзор"
        case .gyroscope: return "Гироскоп"
        case .augmented: return "AR"
        }
    }
    var followsPhone: Bool { self != .explore }
    var usesCamera: Bool { self == .augmented }
    var minimumElevation: Double { usesCamera ? -18 : -90 }
    func basis(manual: DeviceBasis, measured: DeviceBasis?, motionReady: Bool) -> DeviceBasis {
        followsPhone && motionReady ? (measured ?? manual) : manual
    }
}
