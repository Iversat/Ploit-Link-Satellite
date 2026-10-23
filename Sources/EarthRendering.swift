import SceneKit
import MetalKit

// Share GPU textures between the home scene and orbit explorer. Do not retain a
// second decoded UIImage for each 8K map, or upload it again for each screen.
@MainActor enum EarthTextures {
    private static var day: MTLTexture?
    private static var night: MTLTexture?
    private static var loading=false
    private struct Pending {
        weak var material: SCNMaterial?
        weak var view: SCNView?
    }
    private static var pending: [Pending]=[]
    static func apply(to material: SCNMaterial,in view: SCNView) {
        for property in [material.diffuse,material.emission] {
            property.minificationFilter = .linear
            property.magnificationFilter = .linear
            property.mipFilter = .linear
            property.maxAnisotropy = 8
        }
        if let day,let night {
            material.diffuse.contents=day; material.emission.contents=night
            return
        }
        // Show the interface immediately; decode/upload 8K maps off the UI thread.
        material.diffuse.contents=UIImage(named:"earth-day-preview.jpg")
        material.emission.contents=UIImage(named:"earth-night-preview.jpg")
        pending.append(Pending(material:material,view:view))
        guard !loading else { return }
        loading=true
        DispatchQueue.global(qos:.userInitiated).async {
            guard let device=MTLCreateSystemDefaultDevice() else { return }
            let loader=MTKTextureLoader(device:device)
            func load(_ name: String) -> MTLTexture? {
                guard let url=Bundle.main.url(forResource:name,withExtension:"jpg") else { return nil }
                return try? loader.newTexture(URL:url,options:[.SRGB:true,.generateMipmaps:true])
            }
            let loadedDay=load("earth-day"),loadedNight=load("earth-night")
            DispatchQueue.main.async {
                guard let loadedDay,let loadedNight else { loading=false; return }
                day=loadedDay; night=loadedNight
                SCNTransaction.begin(); SCNTransaction.disableActions=true
                for target in pending {
                    target.material?.diffuse.contents=loadedDay
                    target.material?.emission.contents=loadedNight
                    target.view?.setNeedsDisplay()
                }
                SCNTransaction.commit()
                pending=[]; loading=false
                #if DEBUG
                // CI waits for actual 8K readiness before taking visual evidence.
                if ProcessInfo.processInfo.arguments.contains(where:{$0.hasPrefix("--ui-screenshot-")}),
                   let cache=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask).first {
                    try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
                    try? Data("8K ready".utf8).write(to:cache.appendingPathComponent("earth-textures-ready"))
                }
                #endif
            }
        }
    }
}

@MainActor private final class EarthFrameTarget: NSObject {
    weak var view: EarthRenderView?
    init(_ view: EarthRenderView) { self.view=view }
    @objc func tick() { view?.advanceFrame() }
}

class EarthRenderView: SCNView {
    var highRefresh=false { didSet { updateFrameRate() } }
    private var frameLink: CADisplayLink?
    private var onFrame: (() -> Void)?
    private var powerObserver: NSObjectProtocol?
    private var thermalObserver: NSObjectProtocol?
    private var activityObservers: [NSObjectProtocol]=[]
    func startFrameUpdates(_ action: @escaping () -> Void) {
        stopFrameUpdates(); onFrame=action
        let target=EarthFrameTarget(self)
        let link=CADisplayLink(target:target,selector:#selector(EarthFrameTarget.tick))
        frameLink=link; updateFrameRate()
        updateFrameActivity()
        link.add(to:.main,forMode:.common)
    }
    func stopFrameUpdates() { frameLink?.invalidate(); frameLink=nil; onFrame=nil }
    fileprivate func advanceFrame() { onFrame?() }
    private func updateFrameActivity() {
        frameLink?.isPaused=window == nil || UIApplication.shared.applicationState != .active
    }
    static func targetFPS(maximum: Int,lowPower: Bool,thermal: ProcessInfo.ThermalState) -> Int {
        if lowPower || thermal == .serious || thermal == .critical { return 30 }
        return maximum>=120 ? 120:60
    }
    func updateFrameRate() {
        let maximum=window?.screen.maximumFramesPerSecond ?? UIScreen.main.maximumFramesPerSecond
        preferredFramesPerSecond=highRefresh ? Self.targetFPS(maximum:maximum,lowPower:ProcessInfo.processInfo.isLowPowerModeEnabled,thermal:ProcessInfo.processInfo.thermalState):30
        let fps=Float(preferredFramesPerSecond)
        frameLink?.preferredFrameRateRange=CAFrameRateRange(minimum:min(60,fps),maximum:fps,preferred:fps)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Match the display instead of stretching a 2x render target on 3x phones.
        contentScaleFactor=window?.screen.nativeScale ?? UIScreen.main.nativeScale
        updateFrameRate()
        updateFrameActivity()
        if powerObserver == nil {
            powerObserver=NotificationCenter.default.addObserver(forName:.NSProcessInfoPowerStateDidChange,object:nil,queue:.main) { [weak self] _ in self?.updateFrameRate() }
            thermalObserver=NotificationCenter.default.addObserver(forName:ProcessInfo.thermalStateDidChangeNotification,object:nil,queue:.main) { [weak self] _ in self?.updateFrameRate() }
            activityObservers=[UIApplication.didBecomeActiveNotification,UIApplication.didEnterBackgroundNotification].map { name in
                NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.updateFrameActivity() }
            }
            activityObservers.append(NotificationCenter.default.addObserver(forName:UIApplication.willResignActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.frameLink?.isPaused=true })
        }
    }
    deinit {
        frameLink?.invalidate()
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        for observer in activityObservers { NotificationCenter.default.removeObserver(observer) }
    }
}
