import SwiftUI

struct SkyDomeVector: Equatable {
    var x: Double
    var y: Double
    var z: Double
    func dot(_ other: Self) -> Double { x*other.x + y*other.y + z*other.z }
    var normalized: Self {
        let length = sqrt(dot(self))
        guard length > 1e-12 else { return self }
        return .init(x:x/length,y:y/length,z:z/length)
    }
    func interpolated(to other: Self, fraction: Double) -> Self {
        .init(x:x+(other.x-x)*fraction,y:y+(other.y-y)*fraction,z:z+(other.z-z)*fraction)
    }
}

struct SkyDomeProjection {
    let right: SkyDomeVector
    let up: SkyDomeVector
    let towardCamera: SkyDomeVector
    let interior: Bool

    init(yaw: Double = 0, pitch: Double = 32, interior: Bool = false) {
        let a = yaw * .pi / 180, p = pitch * .pi / 180
        // World coordinates: X east, Y north, Z up. The initial camera is south.
        right = .init(x:cos(a),y:sin(a),z:0)
        up = .init(x:-sin(a)*sin(p),y:cos(a)*sin(p),z:cos(p))
        towardCamera = .init(x:sin(a)*cos(p),y:-cos(a)*cos(p),z:sin(p))
        self.interior = interior
    }
    static func vector(_ direction: SkyDirection) -> SkyDomeVector? {
        guard direction.azimuth.isFinite, direction.elevation.isFinite, (-90...90).contains(direction.elevation) else { return nil }
        let a = direction.azimuth * .pi / 180, e = direction.elevation * .pi / 180
        return .init(x:sin(a)*cos(e),y:cos(a)*cos(e),z:sin(e))
    }
    func projected(_ vector: SkyDomeVector) -> (x: Double, y: Double, depth: Double) {
        (vector.dot(right),vector.dot(up),vector.dot(towardCamera))
    }
    func isVisible(_ vector: SkyDomeVector) -> Bool {
        vector.z >= -1e-10 && surfaceDepth(vector) >= -1e-10
    }
    func surfaceDepth(_ vector: SkyDomeVector) -> Double {
        guard interior else { return vector.dot(towardCamera) }
        // A vertical cut opens the near wall, retaining the full sky up to zenith.
        return -vector.x*right.y+vector.y*right.x
    }
    func visiblePolygon(_ vertices: [SkyDomeVector]) -> [SkyDomeVector] {
        guard var previous = vertices.last else { return [] }
        var result: [SkyDomeVector] = []
        var previousDepth = surfaceDepth(previous)
        for vertex in vertices {
            let depth = surfaceDepth(vertex)
            if (depth >= 0) != (previousDepth >= 0) {
                let fraction = previousDepth/(previousDepth-depth)
                result.append(previous.interpolated(to:vertex,fraction:fraction).normalized)
            }
            if depth >= 0 { result.append(vertex) }
            previous = vertex; previousDepth = depth
        }
        return result
    }
    func visibleSegment(from a: SkyDomeVector, to b: SkyDomeVector) -> (SkyDomeVector,SkyDomeVector)? {
        var start = 0.0, end = 1.0
        for (first,last) in [(a.z,b.z),(surfaceDepth(a),surfaceDepth(b))] {
            if first < 0 && last < 0 { return nil }
            if (first < 0) != (last < 0) {
                let crossing = first/(first-last)
                if first < 0 { start = max(start,crossing) } else { end = min(end,crossing) }
            }
        }
        guard start <= end else { return nil }
        return (a.interpolated(to:b,fraction:start).normalized,a.interpolated(to:b,fraction:end).normalized)
    }
}

struct SkyDomeOrientation: Equatable {
    let yaw: Double
    let pitch: Double

    static func resolve(startAzimuth: Double?, viewingDirection: SkyDirection?,
                        yawOffset: Double = 0, pitchOffset: Double = 0) -> Self {
        let start = startAzimuth.flatMap { $0.isFinite ? $0:nil }
        let live = viewingDirection.flatMap {
            $0.azimuth.isFinite && $0.elevation.isFinite && (-90...90).contains($0.elevation) ? $0:nil
        }
        // Place the camera behind the observer and look along this bearing.
        // The cutaway dome exposes the far inner surface in that direction.
        let bearing = live?.azimuth ?? start ?? 180
        return .init(yaw:AimMath.wrap(-bearing+yawOffset),
                     pitch:min(75,max(15,(live?.elevation ?? 32)+pitchOffset)))
    }

    static func liveDirection(basis: DeviceBasis?, motionReady: Bool,
                              northIsTrue: Bool, headingAccuracy: Double) -> SkyDirection? {
        guard motionReady, northIsTrue, headingAccuracy.isFinite,
              (0...20).contains(headingAccuracy), let basis else { return nil }
        let value = AimMath.direction(axis:.back,basis:basis)
        guard value.az.isFinite, value.el.isFinite else { return nil }
        return .init(azimuth:value.az,elevation:value.el)
    }
}

struct SkyDomeTrackSegment {
    let from: SkyDomeVector
    let to: SkyDomeVector

    // Resample only when the forecast changes, not on every motion frame.
    static func make(path: [SkyDirection]) -> [Self] {
        var result: [Self] = []
        for (from,to) in zip(path,path.dropFirst()) {
            guard let a = SkyDomeProjection.vector(from), let b = SkyDomeProjection.vector(to) else { continue }
            let angle = acos(min(1,max(-1,a.dot(b))))
            guard angle < .pi-1e-6 else { continue }
            let count = max(1,Int(ceil(angle / (.pi/90))))
            var previous = a
            for step in 1...count {
                let next = a.interpolated(to:b,fraction:Double(step)/Double(count)).normalized
                result.append(.init(from:previous,to:next)); previous = next
            }
        }
        return result
    }
}

// Rendering density is independent of the capture survey grid.
// Equal-area points avoid dense polar rings; each reads its actual cell.
struct SkyDomePoint {
    let vector: SkyDomeVector
    let cell: Int
    static let mesh: [Self] = {
        let count = 1_536
        let goldenAngle = .pi * (3 - sqrt(5.0))
        return (0..<count).map { index in
            let z = (Double(index)+0.5)/Double(count)
            let azimuth = (Double(index)*goldenAngle).truncatingRemainder(dividingBy:2 * .pi)
            let direction = SkyDirection(azimuth:azimuth*180 / .pi,elevation:asin(z)*180 / .pi)
            return Self(vector:SkyDomeProjection.vector(direction)!,
                        cell:SkySurvey.index(azimuth:direction.azimuth,elevation:direction.elevation)!)
        }
    }()
}

struct SkyDomeObserverPose {
    let forward: SkyDomeVector
    let right: SkyDomeVector

    init(startAzimuth: Double?) {
        let azimuth = startAzimuth.flatMap { $0.isFinite ? $0:nil } ?? 180
        let angle = azimuth * .pi / 180
        forward = .init(x:sin(angle),y:cos(angle),z:0)
        right = .init(x:cos(angle),y:-sin(angle),z:0)
    }

    func point(side: Double = 0, forward distance: Double = 0, height: Double) -> SkyDomeVector {
        .init(x:right.x*side+forward.x*distance,y:right.y*side+forward.y*distance,z:height)
    }

    func handsetPoint(_ side: Double, _ height: Double, surfaceOffset: Double = 0) -> SkyDomeVector {
        let tilt = 18.0 * .pi/180
        return point(side:0.135+side,forward:0.24-height*sin(tilt)+surfaceOffset*cos(tilt),
                     height:0.485+height*cos(tilt)+surfaceOffset*sin(tilt))
    }
}

struct SkyDomeView: View {
    let survey: SkySurvey
    let path: [SkyDirection]
    let direction: SkyDirection?
    var viewingDirection: SkyDirection? = nil
    var startAzimuth: Double? = nil
    var followsPhone = false
    var showPassPath = false
    var sensors: Sensors? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var yaw = 0.0
    @State private var pitch = 32.0
    @State private var dragStart: (yaw: Double,pitch: Double)?
    @State private var trackSegments: [SkyDomeTrackSegment] = []

    private var liveDirection: SkyDirection? {
        guard followsPhone, scenePhase == .active else { return nil }
        if let viewingDirection {
            guard viewingDirection.azimuth.isFinite, viewingDirection.elevation.isFinite,
                  (-90...90).contains(viewingDirection.elevation) else { return nil }
            return viewingDirection
        }
        guard let sensors else { return nil }
        return SkyDomeOrientation.liveDirection(basis:sensors.lastBasis,motionReady:sensors.motionReady,
                                               northIsTrue:sensors.northIsTrue,headingAccuracy:sensors.headingAccuracy)
    }
    private func angles(for live: SkyDirection?) -> SkyDomeOrientation {
        SkyDomeOrientation.resolve(startAzimuth:startAzimuth,viewingDirection:live,
                                   yawOffset:followsPhone ? 0:yaw,pitchOffset:followsPhone ? 0:pitch-32)
    }
    private func reset() { dragStart = nil; yaw = 0; pitch = 32 }
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance:4).onChanged { value in
            if dragStart == nil { dragStart = (yaw,pitch) }
            guard let start = dragStart else { return }
            yaw = AimMath.wrap(start.yaw-Double(value.translation.width)*0.45)
            pitch = min(75,max(15,start.pitch+Double(value.translation.height)*0.3))
        }.onEnded { _ in dragStart = nil }
    }

    var body: some View {
        ZStack(alignment:.topTrailing) {
            // Reuse the existing sensor stream. No extra motion manager or
            // retained timer survives this view; static mode does not tick.
            TimelineView(.animation(minimumInterval:1.0/30,paused:!followsPhone || scenePhase != .active)) { _ in
                let live = liveDirection
                let orientation = angles(for:live)
                ZStack(alignment:.bottom) {
                    Canvas { context,size in draw(in:context,size:size,angles:orientation) }
                        .contentShape(Rectangle())
                        .highPriorityGesture(dragGesture,including:followsPhone ? .none:.all)
                        .accessibilityElement(children:.ignore)
                        .accessibilityLabel("Объёмная точечная карта неба. Человек с iPhone смотрит в сторону начала сканирования. Белый — отмеченное открытое небо, красный — препятствия, серый — не проверено" + (showPassPath ? ", золотой — путь спутника":""))
                        .accessibilityValue(String(format:"yaw %.2f pitch %.2f",locale:Locale(identifier:"en_US_POSIX"),orientation.yaw,orientation.pitch))
                        .accessibilityIdentifier("skyDome")
                    if followsPhone && live == nil {
                        Text("Нужны датчики и точный компас · показано исходное направление")
                            .font(.caption2).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7))
                            .padding(8).background(.black.opacity(0.8),in:RoundedRectangle(cornerRadius:10))
                            .allowsHitTesting(false).accessibilityIdentifier("skyDomeMotionUnavailable")
                    }
                }
            }
            Button(action:reset) {
                Image(systemName:"arrow.counterclockwise").font(.system(size:13,weight:.semibold))
                    .frame(width:44,height:44).background(.black.opacity(0.55),in:Circle())
                    .overlay(Circle().stroke(.white.opacity(0.12),lineWidth:0.5))
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel("Сбросить поворот купола").accessibilityIdentifier("resetSkyDome")
        }
        .onAppear { trackSegments = SkyDomeTrackSegment.make(path:path) }
        .onChange(of:path) { _,value in trackSegments = SkyDomeTrackSegment.make(path:value) }
        .onChange(of:startAzimuth) { _,_ in reset() }
        .onChange(of:followsPhone) { _,_ in reset() }
        .onChange(of:scenePhase) { _,value in if value != .active { dragStart = nil } }
    }

    private func draw(in context: GraphicsContext, size: CGSize, angles: SkyDomeOrientation) {
        let projection = SkyDomeProjection(yaw:angles.yaw,pitch:angles.pitch,interior:true)
        let inclination = sin(angles.pitch * .pi / 180)
        let lift = 0.24
        let labelRadius = 1.19
        let topExtent = max(1+lift*cos(angles.pitch * .pi / 180),labelRadius*inclination)
        let bottomExtent = labelRadius*inclination
        let radius = max(1,min((Double(size.width)-34)/(2*labelRadius),
                             (Double(size.height)-34)/(topExtent+bottomExtent)))
        let center = CGPoint(x:size.width/2,y:CGFloat(17+radius*topExtent))
        func screen(_ point: SkyDomeVector, elevated: Bool = false) -> CGPoint {
            let p = projection.projected(.init(x:point.x,y:point.y,z:point.z+(elevated ? lift:0)))
            return CGPoint(x:center.x+CGFloat(p.x*radius),y:center.y-CGFloat(p.y*radius))
        }
        func floorVector(_ azimuth: Double,_ scale: Double) -> SkyDomeVector {
            let a = azimuth * .pi / 180
            return .init(x:sin(a)*scale,y:cos(a)*scale,z:0)
        }

        let floor = CGRect(x:center.x-CGFloat(radius*1.12),y:center.y-CGFloat(radius*1.12*inclination),
                           width:CGFloat(radius*2.24),height:CGFloat(radius*2.24*inclination))
        context.fill(Path(ellipseIn:floor),with:.radialGradient(Gradient(stops:[
            .init(color:.white.opacity(0.09),location:0),
            .init(color:.white.opacity(0.025),location:0.45),
            .init(color:.clear,location:1)
        ]),center:center,startRadius:0,endRadius:CGFloat(radius*1.12)))
        // The compass belongs to the ground plane, below the floating map.
        for tick in 0..<120 {
            let azimuth = Double(tick)*3
            let offset = tick % 30
            guard offset > 2 && offset < 28 else { continue }
            let a = floorVector(azimuth,1.04), b = floorVector(azimuth,tick % 5 == 0 ? 1.075:1.06)
            var line = Path(); line.move(to:screen(a)); line.addLine(to:screen(b))
            let near = projection.projected(a).depth >= 0
            context.stroke(line,with:.color(.white.opacity(near ? 0.55:0.3)),
                           style:StrokeStyle(lineWidth:0.9,lineCap:.round))
        }
        for (label,azimuth) in [("С",0.0),("В",90.0),("Ю",180.0),("З",270.0)] {
            context.draw(Text(label).font(.system(size:11,weight:.bold)).foregroundStyle(.white.opacity(0.8)),
                         at:screen(floorVector(azimuth,labelRadius)))
        }
        // Batch all points by semantic state and depth, keeping Canvas work
        // bounded while dragging. Hidden hemisphere points remain occluded.
        var clouds = Array(repeating:Path(),count:16)
        for point in SkyDomePoint.mesh {
            guard projection.isVisible(point.vector) else { continue }
            let depth = max(0,min(3,Int(projection.surfaceDepth(point.vector)*4)))
            let state = survey.cells[point.cell]
            let position = screen(point.vector,elevated:true)
            let dotRadius = CGFloat((state == .unknown ? 0.47:0.62)+Double(depth)*0.075)
            clouds[state.rawValue*4+depth].addEllipse(in:CGRect(x:position.x-dotRadius,y:position.y-dotRadius,
                                                             width:dotRadius*2,height:dotRadius*2))
        }
        for state in [SkyCellState.unknown,.observed,.clear,.blocked] {
            for depth in 0..<4 {
                let brightness = Double(depth)/3
                let color: Color
                switch state {
                case .clear: color = .white.opacity(0.48+brightness*0.48)
                case .blocked: color = Color(red:1,green:0.12,blue:0.22).opacity(0.56+brightness*0.44)
                case .observed: color = Color(white:0.42).opacity(0.28+brightness*0.22)
                case .unknown: color = Color(white:0.3).opacity(0.18+brightness*0.13)
                }
                context.fill(clouds[state.rawValue*4+depth],with:.color(color))
            }
        }

        if showPassPath {
            var track = Path()
            for piece in trackSegments {
                if let segment = projection.visibleSegment(from:piece.from,to:piece.to) {
                    track.move(to:screen(segment.0,elevated:true)); track.addLine(to:screen(segment.1,elevated:true))
                }
            }
            context.stroke(track,with:.color(Color(red:1,green:0.79,blue:0.35).opacity(0.65)),
                           style:StrokeStyle(lineWidth:1,lineCap:.round,lineJoin:.round,dash:[3,4]))
        }
        if let direction, let point = SkyDomeProjection.vector(direction), projection.isVisible(point) {
            let p = screen(point,elevated:true)
            context.fill(Path(ellipseIn:CGRect(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(.black.opacity(0.75)))
            context.stroke(Path(ellipseIn:CGRect(x:p.x-4,y:p.y-4,width:8,height:8)),with:.color(.white),lineWidth:1.5)
            context.fill(Path(ellipseIn:CGRect(x:p.x-1,y:p.y-1,width:2,height:2)),with:.color(.white))
        }
        drawObserver(in:context,projection:projection,center:center,radius:radius)
    }

    private func drawObserver(in context: GraphicsContext, projection: SkyDomeProjection,
                              center: CGPoint, radius: Double) {
        let pose = SkyDomeObserverPose(startAzimuth:startAzimuth)
        // The person stays fixed in world space when the map or phone turns.
        // Depth sorting exposes the back, profile or face without mirroring it.
        let scale = max(100,min(145,radius))
        struct Part {
            var path: Path
            var depth: Double
            var white: Double
            var width: CGFloat = 0
            var outline = true
        }
        var parts: [Part] = []
        func screen(_ point: SkyDomeVector) -> CGPoint {
            let p = projection.projected(point)
            return .init(x:center.x+CGFloat(p.x*scale),y:center.y-CGFloat(p.y*scale))
        }
        func limb(_ points: [SkyDomeVector], width: Double, white: Double) {
            guard let first = points.first else { return }
            var path = Path(); path.move(to:screen(first))
            for point in points.dropFirst() { path.addLine(to:screen(point)) }
            let depth = points.map { projection.projected($0).depth }.reduce(0,+)/Double(points.count)
            parts.append(.init(path:path,depth:depth,white:white,width:CGFloat(width*scale)))
        }
        func polygon(_ points: [SkyDomeVector], white: Double, outline: Bool = false) {
            guard let first = points.first else { return }
            var path = Path(); path.move(to:screen(first))
            for point in points.dropFirst() { path.addLine(to:screen(point)) }
            path.closeSubpath()
            let depth = points.map { projection.projected($0).depth }.reduce(0,+)/Double(points.count)
            parts.append(.init(path:path,depth:depth,white:white,outline:outline))
        }
        func sphere(_ point: SkyDomeVector, radius: Double, white: Double, outline: Bool = true) {
            let p = screen(point), r = CGFloat(radius*scale)
            parts.append(.init(path:Path(ellipseIn:CGRect(x:p.x-r,y:p.y-r,width:r*2,height:r*2)),
                               depth:projection.projected(point).depth,white:white,outline:outline))
        }
        let shadow = CGRect(x:center.x-CGFloat(scale*0.22),y:center.y-CGFloat(scale*0.055),
                            width:CGFloat(scale*0.44),height:CGFloat(scale*0.11))
        context.fill(Path(ellipseIn:shadow),with:.color(.black.opacity(0.75)))
        for side in [-1.0,1.0] {
            limb([pose.point(side:side*0.047,height:0.27),
                  pose.point(side:side*0.060,forward:-0.012,height:0.14),
                  pose.point(side:side*0.071,height:0.025)],width:0.056,white:0.24)
            limb([pose.point(side:side*0.075,forward:-0.015,height:0.025),
                  pose.point(side:side*0.075,forward:0.045,height:0.025)],width:0.045,white:0.20)
            let shoulder = pose.point(side:side*0.091,height:0.467)
            let elbow = pose.point(side:side < 0 ? -0.108:0.19,forward:0.11,height:0.37)
            let hand = pose.handsetPoint(side*0.045,-0.05)
            limb([shoulder,elbow],width:0.049,white:0.34)
            limb([elbow,hand],width:0.037,white:0.77)
            sphere(hand,radius:0.023,white:0.82)
        }
        // Rounded shoulder and waist rings give the jacket a soft silhouette.
        let rings = [(width:0.064,depth:0.041,height:0.255),
                     (width:0.104,depth:0.058,height:0.435),
                     (width:0.080,depth:0.045,height:0.485)]
        for (lower,upper) in zip(rings,rings.dropFirst()) {
            for step in 0..<20 {
                let a = Double(step) * .pi/10, b = Double(step+1) * .pi/10
                polygon([pose.point(side:cos(a)*lower.width,forward:sin(a)*lower.depth,height:lower.height),
                         pose.point(side:cos(b)*lower.width,forward:sin(b)*lower.depth,height:lower.height),
                         pose.point(side:cos(b)*upper.width,forward:sin(b)*upper.depth,height:upper.height),
                         pose.point(side:cos(a)*upper.width,forward:sin(a)*upper.depth,height:upper.height)],
                        white:0.31+0.045*cos((a+b)/2))
            }
        }
        limb([pose.point(height:0.475),pose.point(height:0.56)],width:0.047,white:0.76)
        sphere(pose.point(height:0.60),radius:0.056,white:0.84)
        let front = pose.forward.dot(projection.towardCamera)
        if front > -0.15 {
            // A restrained profile cue, without a robotic face or joint markers.
            sphere(pose.point(forward:0.052,height:0.592),radius:0.012,white:0.74,outline:false)
        }
        func phonePanel(x: Double = 0, y: Double = 0, width: Double, height: Double,
                        radius: Double, offset: Double) -> [SkyDomeVector] {
            let corners = [(-width/2+radius,-height/2+radius,180.0),
                           (width/2-radius,-height/2+radius,270.0),
                           (width/2-radius,height/2-radius,0.0),
                           (-width/2+radius,height/2-radius,90.0)]
            return corners.flatMap { corner in
                (0...5).map { step in
                    let angle = (corner.2+Double(step)*18) * .pi/180
                    return pose.handsetPoint(x+corner.0+cos(angle)*radius,y+corner.1+sin(angle)*radius,surfaceOffset:offset)
                }
            }
        }
        func lens(x: Double,y: Double,radius: Double,offset: Double,white: Double) {
            let points = (0..<20).map { step -> SkyDomeVector in
                let angle = Double(step) * .pi/10
                return pose.handsetPoint(x+cos(angle)*radius,y+sin(angle)*radius,surfaceOffset:offset)
            }
            polygon(points,white:white)
        }
        let tilt = 18.0 * .pi/180
        let phoneNormal = SkyDomeVector(x:pose.forward.x*cos(tilt),y:pose.forward.y*cos(tilt),z:sin(tilt))
        let showsBack = phoneNormal.dot(projection.towardCamera) > 0
        let face = showsBack ? 0.004:-0.004
        polygon(phonePanel(width:0.092,height:0.194,radius:0.013,offset:face),white:0.73,outline:true)
        if showsBack {
            polygon(phonePanel(x:0.010,y:0.057,width:0.067,height:0.067,radius:0.010,offset:0.010),white:0.48)
            // Pro camera island: three separate lenses in a triangle.
            for (x,y) in [(0.025,0.076),(0.025,0.038),(-0.009,0.057)] {
                lens(x:x,y:y,radius:0.013,offset:0.012,white:0.67)
                lens(x:x,y:y,radius:0.010,offset:0.013,white:0.06)
                lens(x:x-0.003,y:y+0.003,radius:0.003,offset:0.014,white:0.35)
            }
            lens(x:-0.009,y:0.083,radius:0.004,offset:0.012,white:0.89)
        } else {
            polygon(phonePanel(width:0.081,height:0.180,radius:0.010,offset:-0.006),white:0.12)
            polygon(phonePanel(y:0.075,width:0.027,height:0.008,radius:0.004,offset:-0.007),white:0.025)
            polygon(phonePanel(y:-0.078,width:0.026,height:0.002,radius:0.001,offset:-0.007),white:0.72)
        }
        for part in parts.sorted(by:{ $0.depth < $1.depth }) {
            if part.width > 0 {
                context.stroke(part.path,with:.color(.white.opacity(0.55)),
                               style:StrokeStyle(lineWidth:part.width+0.9,lineCap:.round,lineJoin:.round))
                context.stroke(part.path,with:.color(Color(white:part.white)),
                               style:StrokeStyle(lineWidth:part.width,lineCap:.round,lineJoin:.round))
            } else {
                context.fill(part.path,with:.color(Color(white:part.white)))
                if part.outline { context.stroke(part.path,with:.color(.white.opacity(0.65)),lineWidth:0.65) }
            }
        }
    }
}
