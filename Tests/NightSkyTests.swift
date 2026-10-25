import XCTest
import ImageIO
import Metal
import MetalKit
@testable import PloitSatellite

final class NightSkyTests: XCTestCase {
    func testSiderealReferenceAndLongitude() {
        let j2000 = Date(timeIntervalSince1970:946728000)
        XCTAssertEqual(NightSkyMath.siderealDegrees(at:j2000,longitude:0),280.46061837,accuracy:0.000001)
        XCTAssertEqual(NightSkyMath.siderealDegrees(at:j2000,longitude:90),10.46061837,accuracy:0.000001)
    }
    func testZenithPoleAndRisingSettingDirections() {
        XCTAssertEqual(NightSkyMath.vector(ra:120,dec:45,latitude:45,sidereal:120).up,1,accuracy:1e-9)
        XCTAssertEqual(NightSkyMath.angles(NightSkyMath.vector(ra:0,dec:90,latitude:48,sidereal:40)).elevation,48,accuracy:1e-8)
        let west = NightSkyMath.angles(NightSkyMath.vector(ra:0,dec:0,latitude:0,sidereal:90))
        let east = NightSkyMath.angles(NightSkyMath.vector(ra:180,dec:0,latitude:0,sidereal:90))
        XCTAssertEqual(west.azimuth,270,accuracy:1e-8); XCTAssertEqual(east.azimuth,90,accuracy:1e-8)
    }
    func testProjectionHandlesRollAndRejectsBelowHorizonAndBehind() {
        let basis = NightSkyMath.basis(azimuth:0,elevation:30)
        let projection = NightProjection(basis:basis,size:CGSize(width:400,height:800),focal:300)
        let center = projection.point(basis.z.negative)!
        XCTAssertEqual(center.x,200,accuracy:1e-8); XCTAssertEqual(center.y,400,accuracy:1e-8)
        XCTAssertNil(projection.point(basis.z))
        XCTAssertNil(projection.point(.init(north:0.8,west:0,up:-0.6)))
        XCTAssertEqual(basis.x.dot(basis.y),0,accuracy:1e-8)
        XCTAssertEqual(basis.x.cross(basis.y).dot(basis.z),1,accuracy:1e-8)
    }
    func testCatalogIncludesRealBrightStarsAndConstellations() throws {
        let catalog = try NightSkyCatalog.load()
        XCTAssertEqual(catalog.stars.count,5070)
        let sirius = try XCTUnwrap(catalog.stars.first { $0.name == "Сириус" })
        XCTAssertEqual(sirius.ra,101.287,accuracy:0.01); XCTAssertEqual(sirius.dec,-16.716,accuracy:0.01)
        XCTAssertEqual(Set(catalog.constellations.map(\.id)).count,catalog.constellations.count)
        XCTAssertEqual(catalog.constellations.first { $0.id == "UMa" }?.name,"Большая Медведица")
        XCTAssertNotNil(catalog.constellations.first { $0.id == "UMi" })
        XCTAssertTrue(catalog.stars.allSatisfy { $0.magnitude <= 6 && $0.ra.isFinite && (-90...90).contains($0.dec) })
    }
    func testWholeSkySnapshotsRemainFiniteAndPolygonsClipToViewport() throws {
        let catalog = try NightSkyCatalog.load()
        let snapshot = NightSkySnapshot.make(catalog:catalog,observer:.init(latitude:48.708,longitude:44.513,altitudeM:0),date:Date(timeIntervalSince1970:1792951200))
        XCTAssertEqual(snapshot.stars.count,catalog.stars.count)
        for az in stride(from:0.0,to:360,by:60) {
            let p = NightProjection(basis:NightSkyMath.basis(azimuth:az,elevation:45),size:CGSize(width:400,height:800),focal:280)
            for line in snapshot.lines {
                for point in p.clipped(line) {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                    XCTAssertTrue(p.visible(point,margin:0.01))
                }
            }
        }
    }
    func testPrecessionIdentityAtJ2000AndFiniteAtPoles() {
        let value = NightSkyMath.precess(ra:120,dec:45,at:Date(timeIntervalSince1970:946728000))
        XCTAssertEqual(value.ra,120,accuracy:1e-8); XCTAssertEqual(value.dec,45,accuracy:1e-8)
        for dec in [-90.0,90] {
            let pole = NightSkyMath.precess(ra:0,dec:dec,at:Date(timeIntervalSince1970:1792951200))
            XCTAssertTrue(pole.ra.isFinite && pole.dec.isFinite)
        }
    }
    func testFullSphereAndExpandedARHorizonKeepDirectionsUnchanged() throws {
        let basis = NightSkyMath.basis(azimuth:135,elevation:-30)
        let free = NightProjection(basis:basis,size:CGSize(width:400,height:800),focal:300,minimumElevation:-90)
        let point = try XCTUnwrap(free.point(basis.z.negative))
        XCTAssertEqual(point.x,200,accuracy:0.001); XCTAssertEqual(point.y,400,accuracy:0.001)
        let ar = NightProjection(basis:basis,size:CGSize(width:400,height:800),focal:300,minimumElevation:-18)
        XCTAssertNil(ar.point(basis.z.negative))
        let nearby = NightSkyMath.basis(azimuth:135,elevation:-10).z.negative
        XCTAssertEqual(try XCTUnwrap(ar.point(nearby)),try XCTUnwrap(free.point(nearby)))
    }
    func testPanoramaHasNative16KDetailAndCompleteCompressedMips() throws {
        var bytes = 0
        for index in 0..<NightSkyTexture.levels {
            let part = try NightSkyTexture.level(index)
            XCTAssertEqual(part.width,max(1,16384 >> index))
            XCTAssertEqual(part.height,max(1,8192 >> index))
            bytes += part.data.count-16
        }
        XCTAssertLessThan(bytes,120_000_000)
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let library = try device.makeLibrary(source:NightSkyPanorama.Renderer.shader,options:nil)
        XCTAssertNotNil(library.makeFunction(name:"skyFragment"))
    }
    func testGyroscopeTracksDeviceIncludingRollWithoutUsingCamera() throws {
        let manual = NightSkyMath.basis(azimuth:0,elevation:60)
        let first = NightSkyMath.basis(azimuth:215,elevation:30)
        let moved = NightSkyMath.basis(azimuth:250,elevation:-25)
        let rolled = DeviceBasis(x:moved.y,y:moved.x.negative,z:moved.z)
        for pose in [first,moved,rolled] {
            let basis = NightSkyMode.gyroscope.basis(manual:manual,measured:pose,motionReady:true)
            XCTAssertEqual(basis.x.dot(pose.x),1,accuracy:1e-8)
            XCTAssertEqual(basis.z.dot(pose.z),1,accuracy:1e-8)
            let projection = NightProjection(basis:basis,size:.init(width:400,height:800),focal:300,minimumElevation:NightSkyMode.gyroscope.minimumElevation)
            let center = try XCTUnwrap(projection.point(pose.z.negative))
            XCTAssertEqual(center.x,200,accuracy:1e-8)
            XCTAssertEqual(center.y,400,accuracy:1e-8)
        }
        XCTAssertFalse(NightSkyMode.gyroscope.usesCamera)
        XCTAssertTrue(NightSkyMode.augmented.usesCamera)
        let free = NightSkyMode.explore.basis(manual:manual,measured:moved,motionReady:true)
        XCTAssertEqual(free.z.dot(manual.z),1,accuracy:1e-8)
    }
    func testPanoramaProducesDetailedPixelsInsteadOfBlack() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let texture = try NightSkyTexture.load(device:device)
        let library = try device.makeLibrary(source:NightSkyPanorama.Renderer.shader,options:nil)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name:"skyVertex")
        pipeline.fragmentFunction = library.makeFunction(name:"skyFragment")
        pipeline.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:512,height:256,mipmapped:false)
        target.storageMode = .shared; target.usage = [.renderTarget,.shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor:target))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
        var u = NightSkyPanorama.Uniforms()
        u.right = .init(0,1,0,0); u.up = .init(0,0,1,0); u.forward = .init(1,0,0,0)
        u.equatorialX = .init(1,0,0,0); u.equatorialY = .init(0,1,0,0); u.equatorialZ = .init(0,0,1,0)
        u.viewport = .init(512,256,180,0); u.options = .init(180,0,1,0)
        encoder.setRenderPipelineState(try device.makeRenderPipelineState(descriptor:pipeline))
        encoder.setFragmentBytes(&u,length:MemoryLayout<NightSkyPanorama.Uniforms>.stride,index:0)
        encoder.setFragmentTexture(texture,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed)
        var pixels = [UInt8](repeating:0,count:512*256*4)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:512*4,from:MTLRegionMake2D(0,0,512,256),mipmapLevel:0) }
        let red = stride(from:2,to:pixels.count,by:4).map { pixels[$0] }
        XCTAssertGreaterThan(red.max() ?? 0,100)
        XCTAssertGreaterThan(Set(red).count,80)
        XCTAssertTrue(stride(from:3,to:pixels.count,by:4).allSatisfy { pixels[$0] == 255 })
    }
    @MainActor func testDemoChatValidatesInputAndNeverClaimsRadioDelivery() async throws {
        let suite = "PLS-chat-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let chat = DemoChat(defaults:defaults)
        chat.send(" \n ",satellite:"МКС"); XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(DemoChat.valid(String(repeating:"a",count:281)))
        chat.send("Привет",satellite:"МКС")
        XCTAssertEqual(chat.messages.count,1)
        try await Task.sleep(nanoseconds:1_000_000_000)
        XCTAssertEqual(chat.messages.count,2)
        XCTAssertTrue(chat.messages.last!.text.contains("симулятора"))
        XCTAssertEqual(DemoChat(defaults:defaults).messages.count,2)
        chat.clear(); XCTAssertTrue(chat.messages.isEmpty)
    }
}
