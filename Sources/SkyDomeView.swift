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

    init(yaw: Double = 0, pitch: Double = 32) {
        let a = yaw * .pi / 180, p = pitch * .pi / 180
        // World coordinates: X east, Y north, Z up. The initial camera is south.
        right = .init(x:cos(a),y:sin(a),z:0)
        up = .init(x:-sin(a)*sin(p),y:cos(a)*sin(p),z:cos(p))
        towardCamera = .init(x:sin(a)*cos(p),y:-cos(a)*cos(p),z:sin(p))
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
        vector.z >= -1e-10 && vector.dot(towardCamera) >= -1e-10
    }
    func visiblePolygon(_ vertices: [SkyDomeVector]) -> [SkyDomeVector] {
        guard var previous = vertices.last else { return [] }
        var result: [SkyDomeVector] = []
        var previousDepth = previous.dot(towardCamera)
        for vertex in vertices {
            let depth = vertex.dot(towardCamera)
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
        for (first,last) in [(a.z,b.z),(a.dot(towardCamera),b.dot(towardCamera))] {
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

// A fixed equal-area point set avoids dense polar bands and does not invent
// samples: each decorative point reads the state of its actual survey cell.
struct SkyDomePoint {
    let vector: SkyDomeVector
    let cell: Int
    static let mesh: [Self] = {
        let count = 3_072
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

struct SkyDomeView: View {
    let survey: SkySurvey
    let path: [SkyDirection]
    let direction: SkyDirection?
    var viewingDirection: SkyDirection? = nil
    @State private var yaw = 0.0
    @State private var pitch = 32.0
    @State private var dragStart: (yaw: Double,pitch: Double)?

    // Optional device viewing direction supplies the starting camera bearing;
    // dragging adds a local offset, while reset follows that bearing again.
    private var viewingAngles: (yaw: Double,pitch: Double) {
        guard let viewingDirection, viewingDirection.azimuth.isFinite,
              viewingDirection.elevation.isFinite else { return (yaw,pitch) }
        return (AimMath.wrap(yaw-viewingDirection.azimuth),
                min(75,max(15,viewingDirection.elevation+pitch-32)))
    }

    var body: some View {
        ZStack(alignment:.topTrailing) {
            Canvas { context, size in
                draw(in:context,size:size)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance:4)
                .onChanged { value in
                    if dragStart == nil { dragStart = (yaw,pitch) }
                    guard let start = dragStart else { return }
                    yaw = AimMath.wrap(start.yaw-Double(value.translation.width)*0.45)
                    pitch = min(75,max(15,start.pitch+Double(value.translation.height)*0.3))
                }
                .onEnded { _ in dragStart = nil })
            .accessibilityElement(children:.ignore)
            .accessibilityLabel("Объёмная точечная карта неба. Белый — отмеченное открытое небо, красный — препятствия, тёмный — неизвестно, золотой — путь спутника")
            .accessibilityValue(String(format:"yaw %.2f pitch %.2f",locale:Locale(identifier:"en_US_POSIX"),viewingAngles.yaw,viewingAngles.pitch))
            .accessibilityIdentifier("skyDome")
            Button {
                dragStart = nil; yaw = 0; pitch = 32
            } label: {
                Image(systemName:"arrow.counterclockwise").font(.system(size:13,weight:.semibold))
                    .frame(width:44,height:44).background(.black.opacity(0.55),in:Circle())
                    .overlay(Circle().stroke(.white.opacity(0.12),lineWidth:0.5))
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel("Сбросить поворот купола").accessibilityIdentifier("resetSkyDome")
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let angles = viewingAngles
        let projection = SkyDomeProjection(yaw:angles.yaw,pitch:angles.pitch)
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
        drawDevice(in:context,projection:projection,center:center,radius:radius)

        // Batch all points by semantic state and depth, keeping Canvas work
        // bounded while dragging. Hidden hemisphere points remain occluded.
        var clouds = Array(repeating:Path(),count:16)
        for point in SkyDomePoint.mesh {
            let projected = projection.projected(point.vector)
            guard projection.isVisible(point.vector) else { continue }
            let depth = max(0,min(3,Int(projected.depth*4)))
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

        var track = Path()
        for (from,to) in zip(path,path.dropFirst()) {
            guard let a = SkyDomeProjection.vector(from), let b = SkyDomeProjection.vector(to) else { continue }
            let angle = acos(min(1,max(-1,a.dot(b))))
            guard angle < .pi-1e-6 else { continue }
            let count = max(1,Int(ceil(angle / (.pi/90))))
            var previous = a
            for step in 1...count {
                let next = a.interpolated(to:b,fraction:Double(step)/Double(count)).normalized
                if let segment = projection.visibleSegment(from:previous,to:next) {
                    track.move(to:screen(segment.0,elevated:true)); track.addLine(to:screen(segment.1,elevated:true))
                }
                previous = next
            }
        }
        context.stroke(track,with:.color(Color(red:1,green:0.79,blue:0.35).opacity(0.65)),
                       style:StrokeStyle(lineWidth:1,lineCap:.round,lineJoin:.round,dash:[3,4]))
        if let direction, let point = SkyDomeProjection.vector(direction), projection.isVisible(point) {
            let p = screen(point,elevated:true)
            context.fill(Path(ellipseIn:CGRect(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(.black.opacity(0.75)))
            context.stroke(Path(ellipseIn:CGRect(x:p.x-4,y:p.y-4,width:8,height:8)),with:.color(.white),lineWidth:1.5)
            context.fill(Path(ellipseIn:CGRect(x:p.x-1,y:p.y-1,width:2,height:2)),with:.color(.white))
        }
    }

    private func drawDevice(in context: GraphicsContext, projection: SkyDomeProjection, center: CGPoint, radius: Double) {
        func point(_ x: Double,_ y: Double,_ z: Double = 0.035) -> CGPoint {
            let p = projection.projected(.init(x:x,y:y,z:z))
            return .init(x:center.x+CGFloat(p.x*radius),y:center.y-CGFloat(p.y*radius))
        }
        var phone = Path()
        for (index,corner) in [(-0.075,-0.14),(0.075,-0.14),(0.075,0.14),(-0.075,0.14)].enumerated() {
            let p = point(corner.0,corner.1)
            if index == 0 { phone.move(to:p) } else { phone.addLine(to:p) }
        }
        phone.closeSubpath()
        context.fill(phone,with:.color(Color(white:0.12)))
        context.stroke(phone,with:.color(.white.opacity(0.85)),style:StrokeStyle(lineWidth:1.2,lineJoin:.round))
        var magnet = Path()
        for step in 0...32 {
            let angle = Double(step)/32 * 2 * .pi
            let p = point(cos(angle)*0.044,sin(angle)*0.044,0.04)
            if step == 0 { magnet.move(to:p) } else { magnet.addLine(to:p) }
        }
        context.stroke(magnet,with:.color(.white.opacity(0.5)),lineWidth:0.8)
    }
}
