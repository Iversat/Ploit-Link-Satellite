import SwiftUI
import SceneKit

final class GlobeSceneView: SCNView {
    var layoutCamera: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); layoutCamera?() }
}

struct OrbitScene: UIViewRepresentable {
    var states: [Int:OrbitalState]
    var paths: [Int:OrbitalTrajectory]
    var pathDates: [Int:Date]
    var ids: [Int]
    var labels: [Int:String]
    var selectedID: Int
    var showAll: Bool
    var showGround: Bool
    var observer: Observer?
    var focus: Int
    var animated: Bool
    var onInteraction: (Bool)->Void
    var onSelect: (Int)->Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SCNView {
        let view=GlobeSceneView()
        view.backgroundColor = .black; view.antialiasingMode = .multisampling2X
        view.contentScaleFactor=min(2,UIScreen.main.scale)
        view.preferredFramesPerSecond=ProcessInfo.processInfo.isLowPowerModeEnabled ? 30:60; view.allowsCameraControl=false
        let scene=SCNScene(),root=scene.rootNode
        let sphere=SCNSphere(radius:1); sphere.segmentCount=64
        let earth=SCNMaterial(); earth.lightingModel = .constant
        earth.diffuse.contents=UIImage(named:"earth-day.jpg"); earth.diffuse.intensity=0.6
        earth.emission.contents=UIImage(named:"earth-night.jpg"); earth.emission.intensity=0.8
        sphere.firstMaterial=earth
        let globe=SCNNode(geometry:sphere); globe.scale=SCNVector3(1,0.996647,1); root.addChildNode(globe)
        let air=SCNSphere(radius:1.012); air.segmentCount=40
        let material=SCNMaterial(); material.lightingModel = .constant; material.diffuse.contents=UIColor.clear
        material.blendMode = .add; material.writesToDepthBuffer=false
        material.shaderModifiers=[.fragment:"float rim=pow(1.0-abs(dot(normalize(_surface.normal),normalize(_surface.view))),5.0); _output.color=float4(0.08,0.32,0.7,1.0)*rim*0.55;"]
        air.firstMaterial=material
        let atmosphere=SCNNode(geometry:air); atmosphere.scale=globe.scale; root.addChildNode(atmosphere)
        let camera=SCNNode(); camera.name="camera"; camera.camera=SCNCamera()
        camera.position=SCNVector3(0,0,4.0); camera.camera?.fieldOfView=43
        camera.camera?.projectionDirection = .vertical
        camera.camera?.zNear=0.01; camera.camera?.zFar=100
        // Fixed turntable hierarchy. Never derive "up" from the previous camera pose.
        let yaw=SCNNode(); yaw.name="longitudePivot"
        let pitch=SCNNode(); pitch.name="latitudePivot"
        root.addChildNode(yaw); yaw.addChildNode(pitch); pitch.addChildNode(camera)
        let stars=(0..<350).map { i -> SCNVector3 in
            let y=1-2*Double(i)/350,angle=Double(i)*2.3999632297,r=sqrt(1-y*y)
            return SCNVector3(Float(25*r*cos(angle)),Float(25*y),Float(25*r*sin(angle)))
        }
        let starElement=SCNGeometryElement(indices:Array(0..<Int32(stars.count)),primitiveType:.point)
        starElement.pointSize=1.5; starElement.minimumPointScreenSpaceRadius=0.5; starElement.maximumPointScreenSpaceRadius=1
        let starGeometry=SCNGeometry(sources:[SCNGeometrySource(vertices:stars)],elements:[starElement])
        let starMaterial=SCNMaterial(); starMaterial.lightingModel = .constant; starMaterial.diffuse.contents=UIColor(white:0.6,alpha:1)
        starGeometry.firstMaterial=starMaterial; root.addChildNode(SCNNode(geometry:starGeometry))
        view.scene=scene; view.pointOfView=camera; view.isPlaying=true
        context.coordinator.view=view
        context.coordinator.onInteraction=onInteraction
        view.layoutCamera = { [weak coordinator=context.coordinator] in coordinator?.applyCamera() }
        view.isAccessibilityElement=true; view.accessibilityLabel="Трёхмерная Земля и орбиты спутников. Вращение и масштаб жестами."
        let tap=UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tap(_:)))
        let pan=UIPanGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches=1
        let pinch=UIPinchGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.pinch(_:)))
        tap.require(toFail:pan)
        view.addGestureRecognizer(pan); view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(tap)
        return view
    }
    func updateUIView(_ view: SCNView,context:Context) {
        guard let root=view.scene?.rootNode else { return }
        let coordinator=context.coordinator; coordinator.onSelect=onSelect; coordinator.onInteraction=onInteraction
        let visible=Set(showAll ? ids:[selectedID])
        for id in ids {
            let name="sat-\(id)",pathName="path-\(id)"
            guard visible.contains(id), let state=states[id] else {
                root.childNode(withName:name,recursively:false)?.isHidden=true
                root.childNode(withName:pathName,recursively:false)?.isHidden=true
                continue
            }
            let color=UIColor(OrbitPalette.color(ids.firstIndex(of:id) ?? 0))
            let marker: SCNNode
            if let existing=root.childNode(withName:name,recursively:false) { marker=existing }
            else {
                let dot=SCNSphere(radius:0.018); dot.segmentCount=12
                marker=SCNNode(geometry:dot); marker.name=name
                let m=SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents=color; m.emission.contents=color
                marker.geometry?.firstMaterial=m
                let label=SCNNode(); label.name="label"; label.position=SCNVector3(0,0.05,0)
                label.constraints=[SCNBillboardConstraint()]; marker.addChildNode(label); root.addChildNode(marker)
            }
            marker.isHidden=false
            if coordinator.positions[id] != state.position {
                SCNTransaction.begin()
                SCNTransaction.animationDuration=animated && !UIAccessibility.isReduceMotionEnabled ? 0.48:0
                marker.position=SCNVector3(state.position.sceneX,state.position.sceneY,state.position.sceneZ)
                SCNTransaction.commit()
                coordinator.positions[id]=state.position
            }
            marker.scale=SCNVector3(selectedID==id ? 1.15:0.85,selectedID==id ? 1.15:0.85,selectedID==id ? 1.15:0.85)
            if coordinator.labels[id] != labels[id], let label=marker.childNode(withName:"label",recursively:false) {
                // Rasterize once per changed label, avoiding 3D glyph tessellation during gestures.
                let value=labels[id] ?? ""
                let style=NSMutableParagraphStyle(); style.alignment = .center
                let attrs: [NSAttributedString.Key:Any]=[.font:UIFont.systemFont(ofSize:26,weight:.semibold),.foregroundColor:UIColor.white,.paragraphStyle:style]
                let size=CGSize(width:360,height:80)
                let format=UIGraphicsImageRendererFormat(); format.scale=1
                let image=UIGraphicsImageRenderer(size:size,format:format).image { _ in
                    (value as NSString).draw(in:CGRect(origin:.zero,size:size),withAttributes:attrs)
                }
                let plane=SCNPlane(width:0.48,height:0.107)
                let material=SCNMaterial(); material.lightingModel = .constant
                material.diffuse.contents=image; material.isDoubleSided=true; material.writesToDepthBuffer=false
                plane.firstMaterial=material; label.geometry=plane
                coordinator.labels[id]=labels[id]
            }
            let key="\(id)-\(showGround)-\(pathDates[id]?.timeIntervalSince1970 ?? 0)-\(paths[id]?.orbit.first?.x ?? 0)-\(selectedID==id)"
            if coordinator.pathKeys[id] != key, let path=paths[id] {
                root.childNode(withName:pathName,recursively:false)?.removeFromParentNode()
                let points=(showGround ? path.ground:path.orbit).map { SCNVector3($0.sceneX,$0.sceneY,$0.sceneZ) }
                let indices=(0..<max(0,points.count-1)).flatMap { [Int32($0),Int32($0+1)] }
                let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:points)],elements:[SCNGeometryElement(indices:indices,primitiveType:.line)])
                let m=SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents=color.withAlphaComponent(selectedID==id ? 0.95:0.35)
                geometry.firstMaterial=m
                let node=SCNNode(geometry:geometry); node.name=pathName; root.addChildNode(node)
                coordinator.pathKeys[id]=key
            }
            root.childNode(withName:pathName,recursively:false)?.isHidden=false
        }
        if let observer {
            let lat=observer.latitude*Double.pi/180,lon=observer.longitude*Double.pi/180
            let n=6378.137/sqrt(1-0.00669438*pow(sin(lat),2))
            let p=OrbitPoint(x:(n+15)*cos(lat)*cos(lon),y:(n+15)*cos(lat)*sin(lon),z:(n*(1-0.00669438)+15)*sin(lat))
            let node=root.childNode(withName:"observer",recursively:false) ?? SCNNode(geometry:SCNSphere(radius:0.012))
            node.name="observer"; node.geometry?.firstMaterial?.diffuse.contents=UIColor.systemGreen
            node.position=SCNVector3(p.sceneX,p.sceneY,p.sceneZ)
            if node.parent == nil { root.addChildNode(node) }
        }
        if coordinator.lastFocus != focus || (!coordinator.didFocus && states[selectedID] != nil),
           let point=states[selectedID]?.position {
            let length=sqrt(point.sceneX*point.sceneX+point.sceneY*point.sceneY+point.sceneZ*point.sceneZ)
            coordinator.camera.yaw=Double(atan2(point.sceneX,point.sceneZ))*180 / .pi
            coordinator.camera.pitch=min(85,max(-85,Double(asin(point.sceneY/length))*180 / .pi))
            coordinator.camera.zoom=1
            coordinator.applyCamera()
            coordinator.lastFocus=focus; coordinator.didFocus=true
        }
        view.setNeedsDisplay()
    }
    final class Coordinator: NSObject {
        var onSelect: ((Int)->Void)?
        var lastFocus = -1
        var didFocus=false
        var labels: [Int:String]=[:]
        var pathKeys: [Int:String]=[:]
        weak var view: SCNView?
        var positions: [Int:OrbitPoint]=[:]
        var onInteraction: ((Bool)->Void)?
        var camera=GlobeCamera()
        var drag=GlobeDrag()
        func applyCamera() {
            guard let view, let node=view.pointOfView,view.bounds.width>0,view.bounds.height>0 else { return }
            let halfVertical=43.0 * Double.pi/360
            let halfHorizontal=atan(tan(halfVertical)*Double(view.bounds.width/view.bounds.height))
            let distance=1.22/sin(min(halfVertical,halfHorizontal))/camera.zoom
            SCNTransaction.begin(); SCNTransaction.disableActions=true
            node.parent?.parent?.eulerAngles=SCNVector3(0,Float(camera.yaw * .pi/180),0)
            node.parent?.eulerAngles=SCNVector3(Float(-camera.pitch * .pi/180),0,0)
            node.eulerAngles=SCNVector3Zero
            node.position=SCNVector3(0,0,Float(distance))
            SCNTransaction.commit()
            #if DEBUG
            view.accessibilityValue=String(format:"yaw %.1f pitch %.1f zoom %.2f center 0 0",camera.yaw,camera.pitch,camera.zoom)
            #endif
        }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            if gesture.state == .began { drag.begin(camera); onInteraction?(true) }
            let delta=gesture.translation(in:view)
            camera=drag.update(x:Double(delta.x),y:Double(delta.y),width:Double(view.bounds.width))
            applyCamera()
            if [.ended,.cancelled,.failed].contains(gesture.state) { onInteraction?(false) }
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began { onInteraction?(true) }
            camera.magnify(Double(gesture.scale)); gesture.scale=1; applyCamera()
            if [.ended,.cancelled,.failed].contains(gesture.state) { onInteraction?(false) }
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view=gesture.view as? SCNView else { return }
            for hit in view.hitTest(gesture.location(in:view),options:nil) {
                var node: SCNNode?=hit.node
                while let current=node {
                    if let name=current.name,name.hasPrefix("sat-"),let id=Int(name.dropFirst(4)) { onSelect?(id); return }
                    node=current.parent
                }
            }
        }
    }
}
