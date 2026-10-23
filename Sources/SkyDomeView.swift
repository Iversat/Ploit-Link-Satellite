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

private struct SkyDomePatch {
    let cell: Int
    let vertices: [SkyDomeVector]
    let normal: SkyDomeVector
    static let mesh: [Self] = {
        var patches: [Self] = []
        for row in 0..<SkySurvey.rows { for column in 0..<SkySurvey.columns {
            for vertical in 0..<2 { for horizontal in 0..<2 {
                let a = Double(column)*15 + Double(horizontal)*7.5
                let e = Double(row)*10 + Double(vertical)*5
                func vertex(_ az: Double,_ el: Double) -> SkyDomeVector {
                    SkyDomeProjection.vector(.init(azimuth:az,elevation:el))!
                }
                patches.append(.init(cell:row*SkySurvey.columns+column,
                    vertices:[vertex(a,e),vertex(a+7.5,e),vertex(a+7.5,e+5),vertex(a,e+5)],
                    normal:vertex(a+3.75,e+2.5)))
            } }
        } }
        return patches
    }()
}

struct SkyDomeView: View {
    let survey: SkySurvey
    let path: [SkyDirection]
    let direction: SkyDirection?
    @State private var yaw = 0.0
    @State private var pitch = 32.0
    @State private var dragStart: (yaw: Double,pitch: Double)?

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
            .accessibilityLabel("Объёмная карта обзора неба. Голубой — отмеченное небо, красный — препятствия, серый — неизвестно, жёлтый — путь спутника")
            .accessibilityValue(String(format:"yaw %.2f pitch %.2f",locale:Locale(identifier:"en_US_POSIX"),yaw,pitch))
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
        let projection = SkyDomeProjection(yaw:yaw,pitch:pitch)
        let inclination = sin(pitch * .pi / 180)
        let radius = max(1,min((Double(size.width)-60)/2,(Double(size.height)-58)/(1+inclination)))
        let center = CGPoint(x:size.width/2,y:CGFloat(27+radius))
        func screen(_ point: SkyDomeVector) -> CGPoint {
            let p = projection.projected(point)
            return CGPoint(x:center.x+CGFloat(p.x*radius),y:center.y-CGFloat(p.y*radius))
        }
        let base = CGRect(x:center.x-CGFloat(radius),y:center.y-CGFloat(radius*inclination),width:CGFloat(radius*2),height:CGFloat(radius*inclination*2))
        context.fill(Path(ellipseIn:base.insetBy(dx:-6,dy:-4)),with:.color(.black.opacity(0.4)))
        context.fill(Path(ellipseIn:base),with:.color(Color(red:0.015,green:0.02,blue:0.025)))
        context.stroke(Path(ellipseIn:base),with:.color(.white.opacity(0.1)),lineWidth:1)

        let light = SkyDomeVector(x:-0.45,y:-0.35,z:0.82).normalized
        let patches = SkyDomePatch.mesh.compactMap { patch -> (SkyDomePatch,[SkyDomeVector],Double)? in
            let vertices = projection.visiblePolygon(patch.vertices)
            guard vertices.count >= 3 else { return nil }
            return (patch,vertices,patch.normal.dot(projection.towardCamera))
        }.sorted { $0.2 < $1.2 }
        for (patch,vertices,_) in patches {
            var shape = Path(); shape.move(to:screen(vertices[0]))
            for vertex in vertices.dropFirst() { shape.addLine(to:screen(vertex)) }
            shape.closeSubpath()
            let color = surfaceColor(survey.cells[patch.cell],normal:patch.normal,light:light)
            // Shared polygon edges stay solid; independent edge antialiasing
            // exposes the background as thin seams between adjacent patches.
            context.fill(shape,with:.color(color),style:FillStyle(antialiased:false))
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
                    track.move(to:screen(segment.0)); track.addLine(to:screen(segment.1))
                }
                previous = next
            }
        }
        context.stroke(track,with:.color(.black.opacity(0.35)),style:StrokeStyle(lineWidth:4,lineCap:.round,lineJoin:.round))
        context.stroke(track,with:.color(Color(red:1,green:0.83,blue:0.32)),style:StrokeStyle(lineWidth:2,lineCap:.round,lineJoin:.round))
        if let direction, let point = SkyDomeProjection.vector(direction), projection.isVisible(point) {
            let p = screen(point)
            context.fill(Path(ellipseIn:CGRect(x:p.x-7,y:p.y-7,width:14,height:14)),with:.color(.black.opacity(0.5)))
            context.stroke(Path(ellipseIn:CGRect(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(.white),lineWidth:2)
            context.fill(Path(ellipseIn:CGRect(x:p.x-1.5,y:p.y-1.5,width:3,height:3)),with:.color(.white))
        }
        for (label,azimuth) in [("С",0.0),("В",90.0),("Ю",180.0),("З",270.0)] {
            guard let vector = SkyDomeProjection.vector(.init(azimuth:azimuth,elevation:0)) else { continue }
            let p = projection.projected(vector)
            // Keep all compass labels outside the silhouette, including the
            // northern horizon that the opaque front of the dome conceals.
            let verticalRadius = p.y >= 0 ? radius : radius*inclination
            let multiplier = 1/sqrt(pow(p.x/radius,2)+pow(p.y/verticalRadius,2))
            let length = sqrt(p.x*p.x+p.y*p.y)
            let point = CGPoint(x:center.x+CGFloat(p.x*(multiplier+15/length)),y:center.y-CGFloat(p.y*(multiplier+15/length)))
            context.draw(Text(label).font(.system(size:11,weight:.semibold)).foregroundStyle(.white.opacity(0.65)),at:point)
        }
    }

    private func surfaceColor(_ state: SkyCellState, normal: SkyDomeVector, light: SkyDomeVector) -> Color {
        let base: (Double,Double,Double)
        switch state {
        case .clear: base = (0.16,0.66,0.94)
        case .blocked: base = (0.95,0.20,0.30)
        case .observed: base = (0.25,0.29,0.34)
        case .unknown: base = (0.15,0.18,0.22)
        }
        let shade = 0.48+0.52*max(0,normal.dot(light))
        return Color(red:base.0*shade,green:base.1*shade,blue:base.2*shade)
    }
}
