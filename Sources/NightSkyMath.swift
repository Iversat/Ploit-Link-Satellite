import Foundation
import CoreGraphics

struct CatalogStar: Decodable, Identifiable {
    let id: Int
    let name: String
    let ra: Double
    let dec: Double
    let magnitude: Double
    let color: Double
}
struct CatalogConstellation: Decodable, Identifiable {
    let id: String
    let name: String
    let ra: Double
    let dec: Double
    let lines: [[[Double]]]
}
struct NightSkyCatalog: Decodable {
    let stars: [CatalogStar]
    let constellations: [CatalogConstellation]
    let milkyWay: [[[Double]]]
    static func load() throws -> Self {
        guard let url = Bundle.main.url(forResource:"NightSky",withExtension:"json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Self.self,from:Data(contentsOf:url))
    }
}

struct NightTarget: Identifiable, Equatable {
    var id: String
    var name: String
    var ra: Double
    var dec: Double
    var detail: String
    static let milkyWay = NightTarget(id:"milkyway",name:"Млечный Путь · Лебедь",ra:305,dec:40,
        detail:"Яркая область полосы Млечного Пути. Для наблюдения нужны тёмное место, ясное небо и отсутствие яркой Луны.")
    static let galacticCenter = NightTarget(id:"galactic-center",name:"Центр Млечного Пути",ra:266.4051,dec:-28.9362,
        detail:"Направление на центр Галактики в Стрельце. Его высота сильно зависит от широты и времени года.")
}

enum NightSkyMath {
    static let radians = Double.pi/180
    static func siderealDegrees(at date: Date, longitude: Double) -> Double {
        let jd = date.timeIntervalSince1970/86400+2440587.5
        let d = jd-2451545, t = d/36525
        let value = 280.46061837+360.98564736629*d+0.000387933*t*t-t*t*t/38710000+longitude
        return (value.truncatingRemainder(dividingBy:360)+360).truncatingRemainder(dividingBy:360)
    }
    static func precess(ra: Double, dec: Double, at date: Date) -> (ra:Double,dec:Double) {
        let t = (date.timeIntervalSince1970/86400+2440587.5-2451545)/36525
        let zeta = (2306.2181*t+0.30188*t*t+0.017998*t*t*t)/3600*radians
        let z = (2306.2181*t+1.09468*t*t+0.018203*t*t*t)/3600*radians
        let theta = (2004.3109*t-0.42665*t*t-0.041833*t*t*t)/3600*radians
        let a = ra*radians+zeta, d = dec*radians
        let x = cos(theta)*cos(d)*cos(a)-sin(theta)*sin(d)
        let y = cos(d)*sin(a)
        let up = sin(theta)*cos(d)*cos(a)+cos(theta)*sin(d)
        return ((atan2(y,x)+z)/radians,asin(max(-1,min(1,up)))/radians)
    }
    static func vector(ra: Double, dec: Double, latitude: Double, sidereal: Double) -> DirectionVector {
        let h = (sidereal-ra)*radians, d = dec*radians, p = latitude*radians
        return .init(north:sin(d)*cos(p)-cos(d)*cos(h)*sin(p),
                     west:cos(d)*sin(h),up:sin(d)*sin(p)+cos(d)*cos(h)*cos(p))
    }
    static func vector(ra: Double, dec: Double, observer: Observer, date: Date) -> DirectionVector {
        let current = precess(ra:ra,dec:dec,at:date)
        return vector(ra:current.ra,dec:current.dec,latitude:observer.latitude,
                      sidereal:siderealDegrees(at:date,longitude:observer.longitude))
    }
    static func angles(_ v: DirectionVector) -> SkyDirection {
        .init(azimuth:(atan2(-v.west,v.north)/radians+360).truncatingRemainder(dividingBy:360),
              elevation:asin(max(-1,min(1,v.up)))/radians)
    }
    static func basis(azimuth: Double, elevation: Double) -> DeviceBasis {
        let a = azimuth*radians, e = elevation*radians
        return .init(x:.init(north:-sin(a),west:-cos(a),up:0),
                     y:.init(north:-sin(e)*cos(a),west:sin(e)*sin(a),up:cos(e)),
                     z:.init(north:-cos(e)*cos(a),west:cos(e)*sin(a),up:-sin(e)))
    }
    static func sunElevation(observer: Observer, date: Date) -> Double {
        let n = date.timeIntervalSince1970/86400+2440587.5-2451545
        let g = (357.528+0.9856003*n)*radians
        let l = (280.460+0.9856474*n+1.915*sin(g)+0.020*sin(2*g))*radians
        let ob = (23.439-0.0000004*n)*radians
        let v = vector(ra:atan2(cos(ob)*sin(l),cos(l))/radians,dec:asin(sin(ob)*sin(l))/radians,
                       latitude:observer.latitude,sidereal:siderealDegrees(at:date,longitude:observer.longitude))
        return angles(v).elevation
    }
}

struct NightSkySnapshot {
    var stars: [DirectionVector] = []
    var lines: [[DirectionVector]] = []
    var labels: [DirectionVector] = []
    var milkyWay: [[DirectionVector]] = []
    static func make(catalog: NightSkyCatalog, observer: Observer, date: Date) -> Self {
        func convert(_ ra: Double,_ dec: Double) -> DirectionVector {
            NightSkyMath.vector(ra:ra,dec:dec,observer:observer,date:date)
        }
        return .init(stars:catalog.stars.map { convert($0.ra,$0.dec) },
                     lines:catalog.constellations.flatMap { $0.lines.map { $0.map { convert($0[0],$0[1]) } } },
                     labels:catalog.constellations.map { convert($0.ra,$0.dec) },
                     milkyWay:catalog.milkyWay.map { $0.map { convert($0[0],$0[1]) } })
    }
}

struct NightProjection {
    var basis: DeviceBasis
    var size: CGSize
    var focal: Double
    var forward: DirectionVector { basis.z.negative }
    func point(_ vector: DirectionVector, aboveHorizon: Bool = true) -> CGPoint? {
        let depth = vector.dot(forward)
        guard depth > 0.02, !aboveHorizon || vector.up >= 0 else { return nil }
        return CGPoint(x:Double(size.width)/2+vector.dot(basis.x)*focal/depth,
                       y:Double(size.height)/2-vector.dot(basis.y)*focal/depth)
    }
    func visible(_ point: CGPoint, margin: Double = 0) -> Bool {
        point.x >= -margin && point.y >= -margin && point.x <= size.width+margin && point.y <= size.height+margin
    }
    // Clip sky polygons against the horizon, near plane and all four view edges.
    // This avoids giant stripes when the Milky Way crosses the back of the view.
    func clipped(_ input: [DirectionVector]) -> [CGPoint] {
        let halfW = Double(size.width)/2/focal, halfH = Double(size.height)/2/focal
        let forward = forward, basis = basis
        let planes: [(DirectionVector)->Double] = [
            { $0.up }, { $0.dot(forward)-0.02 },
            { $0.dot(forward)*halfW+$0.dot(basis.x) }, { $0.dot(forward)*halfW-$0.dot(basis.x) },
            { $0.dot(forward)*halfH+$0.dot(basis.y) }, { $0.dot(forward)*halfH-$0.dot(basis.y) }
        ]
        var polygon = input
        for distance in planes {
            guard let last = polygon.last else { return [] }
            var result: [DirectionVector] = [], a = last, da = distance(last)
            for b in polygon {
                let db = distance(b)
                if (da >= 0) != (db >= 0) {
                    let t = da/(da-db)
                    result.append(.init(north:a.north+(b.north-a.north)*t,
                                        west:a.west+(b.west-a.west)*t,up:a.up+(b.up-a.up)*t))
                }
                if db >= 0 { result.append(b) }
                a = b; da = db
            }
            polygon = result
        }
        return polygon.compactMap { point($0,aboveHorizon:false) }
    }
}
