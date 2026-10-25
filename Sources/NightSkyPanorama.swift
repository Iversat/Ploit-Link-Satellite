import SwiftUI
import MetalKit

/// Native-resolution inverse spherical projection. No intermediate blurred bitmap.
struct NightSkyPanorama: UIViewRepresentable {
    let basis: DeviceBasis
    let observer: Observer
    let date: Date
    let focal: Double
    let augmented: Bool
    let enabled: Bool
    var onError: (String) -> Void

    func makeCoordinator() -> Renderer { Renderer() }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame:.zero,device:MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.isOpaque = false; view.backgroundColor = .clear
        view.clearColor = MTLClearColorMake(0,0,0,0)
        view.isPaused = true; view.enableSetNeedsDisplay = true
        view.contentScaleFactor = UIScreen.main.nativeScale
        view.delegate = context.coordinator
        context.coordinator.prepare(view:view,onError:onError)
        return view
    }
    func updateUIView(_ view: MTKView, context: Context) {
        let convert: (DirectionVector)->SIMD4<Float> = { .init(Float($0.north),Float($0.west),Float($0.up),0) }
        var u = Uniforms()
        u.right = convert(basis.x); u.up = convert(basis.y); u.forward = convert(basis.z.negative)
        u.equatorialX = convert(NightSkyMath.vector(ra:0,dec:0,observer:observer,date:date))
        u.equatorialY = convert(NightSkyMath.vector(ra:90,dec:0,observer:observer,date:date))
        u.equatorialZ = convert(NightSkyMath.vector(ra:0,dec:90,observer:observer,date:date))
        u.options = .init(Float(focal),augmented ? 1:0,enabled ? 1:0,0)
        context.coordinator.uniforms = u
        view.setNeedsDisplay()
    }
    struct Uniforms {
        var right = SIMD4<Float>(), up = SIMD4<Float>(), forward = SIMD4<Float>()
        var equatorialX = SIMD4<Float>(), equatorialY = SIMD4<Float>(), equatorialZ = SIMD4<Float>()
        var viewport = SIMD4<Float>(), options = SIMD4<Float>()
    }
    final class Renderer: NSObject, MTKViewDelegate {
        var uniforms = Uniforms()
        private var pipeline: MTLRenderPipelineState?
        private var texture: MTLTexture?
        private var queue: MTLCommandQueue?
        func prepare(view: MTKView,onError: @escaping (String)->Void) {
            guard let device = view.device else { onError("Детальная панорама недоступна на этом устройстве."); return }
            DispatchQueue.global(qos:.userInitiated).async { [weak self,weak view] in
                do {
                    guard let url = Bundle.main.url(forResource:"night-sky-panorama",withExtension:"jpg") else { throw CocoaError(.fileNoSuchFile) }
                    let library = try device.makeLibrary(source:Self.shader,options:nil)
                    let descriptor = MTLRenderPipelineDescriptor()
                    descriptor.vertexFunction = library.makeFunction(name:"skyVertex")
                    descriptor.fragmentFunction = library.makeFunction(name:"skyFragment")
                    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
                    let pipeline = try device.makeRenderPipelineState(descriptor:descriptor)
                    let texture = try MTKTextureLoader(device:device).newTexture(URL:url,options:[.SRGB:true,.generateMipmaps:true,.textureUsage:MTLTextureUsage.shaderRead.rawValue])
                    DispatchQueue.main.async {
                        guard let self,let view else { return }
                        self.pipeline = pipeline; self.texture = texture; self.queue = device.makeCommandQueue()
                        view.setNeedsDisplay()
                    }
                } catch {
                    DispatchQueue.main.async { onError("Не удалось открыть детальную панораму. Каталог звёзд остаётся доступен.") }
                }
            }
        }
        func mtkView(_ view: MTKView,drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }
        func draw(in view: MTKView) {
            guard let pipeline,let texture,let command = queue?.makeCommandBuffer(),
                  let pass = view.currentRenderPassDescriptor,let drawable = view.currentDrawable,
                  let encoder = command.makeRenderCommandEncoder(descriptor:pass),view.bounds.width > 0 else { return }
            var u = uniforms
            let scale = Float(view.drawableSize.width/view.bounds.width)
            u.viewport = .init(Float(view.drawableSize.width),Float(view.drawableSize.height),u.options.x*scale,0)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0)
            encoder.setFragmentTexture(texture,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
            encoder.endEncoding(); command.present(drawable); command.commit()
        }
        static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct SkyV { float4 position [[position]]; };
        struct U { float4 right, up, forward, ex, ey, ez, viewport, options; };
        vertex SkyV skyVertex(uint id [[vertex_id]]) {
            float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
            return {float4(p[id],0,1)};
        }
        fragment float4 skyFragment(SkyV in [[stage_in]],constant U &u [[buffer(0)]],texture2d<float> sky [[texture(0)]]) {
            if (u.options.z < 0.5) return float4(0);
            float2 p = (in.position.xy-u.viewport.xy*0.5)/u.viewport.z;
            float3 world = normalize(u.forward.xyz+p.x*u.right.xyz-p.y*u.up.xyz);
            float3 eq = float3(dot(world,u.ex.xyz),dot(world,u.ey.xyz),dot(world,u.ez.xyz));
            float3 gal = float3(dot(eq,float3(-0.0548755604,-0.8734370902,-0.4838350155)),
                                dot(eq,float3(0.4941094279,-0.4448296300,0.7469822445)),
                                dot(eq,float3(-0.8676661490,-0.1980763734,0.4559837762)));
            float2 uv = float2(0.5-atan2(gal.y,gal.x)/(2*M_PI_F),0.5-asin(clamp(gal.z,-1.0f,1.0f))/M_PI_F);
            constexpr sampler s(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear,mip_filter::linear);
            float3 rgb = sky.sample(s,uv).rgb;
            if (u.options.y > 0.5) {
                float a = smoothstep(-0.31f,-0.23f,world.z)*min(0.65f,max(rgb.r,max(rgb.g,rgb.b))*3.0f);
                return float4(rgb*a,a);
            }
            rgb *= mix(0.48f,1.0f,smoothstep(-0.025f,0.025f,world.z));
            return float4(rgb,1);
        }
        """
    }
}
