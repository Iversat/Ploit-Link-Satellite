import SceneKit

// Fit the globe in the space between floating controls, while rendering into
// the entire display. An asymmetric frustum moves its screen centre without
// translating the Earth, tilting the camera or clipping at the panel edge.
struct GlobeFraming {
    let distance: Double
    let projection: SCNMatrix4
    init(size: CGSize, insets: UIEdgeInsets, zoom: Double) {
        let width=max(1,Double(size.width)),height=max(1,Double(size.height))
        let top=min(height-1,max(0,Double(insets.top)))
        let bottom=min(height-top-1,max(0,Double(insets.bottom)))
        let available=max(1,height-top-bottom)
        let halfVertical=43.0 * Double.pi/360
        let halfHorizontal=atan(tan(halfVertical)*width/height)
        let halfVisible=atan(tan(halfVertical)*available/height)
        distance=1.22/sin(min(halfVisible,halfHorizontal))/max(0.8,min(1.65,zoom))
        let near=0.01,far=100.0,f=1/tan(halfVertical)
        var matrix=SCNMatrix4Identity
        matrix.m11=Float(f*height/width)
        matrix.m22=Float(f)
        matrix.m32=Float((top+available/2)*2/height-1)
        matrix.m33=Float((far+near)/(near-far))
        matrix.m34 = -1
        matrix.m43=Float(2*far*near/(near-far))
        matrix.m44=0
        projection=matrix
    }
}
