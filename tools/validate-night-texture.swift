import Foundation
import MetalKit

/// Exercise the physical 16K texture path on the host Apple GPU, beyond Simulator's 8K limit.
@main struct ValidateNightTexture {
    static func main() throws {
        let device = MTLCreateSystemDefaultDevice()!
        precondition(device.supportsFamily(.apple3), "A 16K-capable Apple GPU is required")
        let texture = try NightSkyTexture.load(device:device)
        precondition(texture.width == 16384 && texture.height == 8192)
        precondition(texture.mipmapLevelCount == 15)
        let library = try device.makeLibrary(source:"""
        #include <metal_stdlib>
        using namespace metal;
        kernel void inspect(texture2d<float> sky [[texture(0)]],device float4 *out [[buffer(0)]],uint i [[thread_position_in_grid]]) {
            constexpr sampler s(coord::normalized,filter::linear,mip_filter::linear);
            out[i] = sky.sample(s,float2(float(i%256)/256.0,float(i/256)/128.0),level(0));
        }
        """,options:nil)
        let pipeline = try device.makeComputePipelineState(function:library.makeFunction(name:"inspect")!)
        let count = 256*128
        let buffer = device.makeBuffer(length:count*MemoryLayout<SIMD4<Float>>.stride,options:.storageModeShared)!
        let queue = device.makeCommandQueue()!, command = queue.makeCommandBuffer()!
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline); encoder.setTexture(texture,index:0); encoder.setBuffer(buffer,offset:0,index:0)
        encoder.dispatchThreads(.init(width:count,height:1,depth:1),threadsPerThreadgroup:.init(width:64,height:1,depth:1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        precondition(command.status == .completed, "16K GPU command failed")
        let samples = buffer.contents().bindMemory(to:SIMD4<Float>.self,capacity:count)
        let brightness = (0..<count).map { max(samples[$0].x,max(samples[$0].y,samples[$0].z)) }
        precondition(brightness.allSatisfy(\.isFinite))
        precondition(brightness.max()! > 0.2 && brightness.min()! < 0.01, "Missing sky detail")
        print("16K ASTC GPU sampling passed on \(device.name); \(texture.width)x\(texture.height); 15 mip levels; range \(brightness.min()!)...\(brightness.max()!)")
    }
}
