import SwiftUI

// Geometry matches docs/brand/pls-symbol.svg and the packaged app icon.
struct PLSGlyph: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            context.translateBy(x:(size.width-side)/2, y:(size.height-side)/2)
            context.scaleBy(x:side/256, y:side/256)
            context.drawLayer { layer in
                func polygon(_ points: [CGPoint]) {
                    var path = Path(); path.addLines(points); path.closeSubpath()
                    layer.fill(path, with:.color(.white))
                }
                func line(_ points:[CGPoint], width:CGFloat) {
                    var path = Path(); path.addLines(points)
                    layer.stroke(path,with:.color(.white),style:StrokeStyle(lineWidth:width,lineCap:.round,lineJoin:.round))
                }
                line([CGPoint(x:66.0925,y:166.6841),CGPoint(x:189.9075,y:89.3159)],width:9)
                polygon([CGPoint(x:43.3042,y:149.086),CGPoint(x:84.8585,y:123.12),CGPoint(x:113.4742,y:168.9146),CGPoint(x:71.9198,y:194.8806)])
                polygon([CGPoint(x:95.7786,y:100.967),CGPoint(x:117.8279,y:87.1891),CGPoint(x:160.2214,y:155.033),CGPoint(x:138.1721,y:168.8109)])
                polygon([CGPoint(x:142.5258,y:87.0854),CGPoint(x:184.0802,y:61.1194),CGPoint(x:212.6958,y:106.914),CGPoint(x:171.1415,y:132.88)])
                var arc = Path()
                arc.addArc(center:CGPoint(x:128,y:128),radius:99,startAngle:.degrees(12),endAngle:.degrees(106),clockwise:false)
                layer.stroke(arc,with:.color(.white),style:StrokeStyle(lineWidth:4,lineCap:.round))
                layer.blendMode = .destinationOut
                line([CGPoint(x:65.777,y:139.7601),CGPoint(x:90.1533,y:178.7703)],width:3)
                line([CGPoint(x:165.8467,y:77.2297),CGPoint(x:190.223,y:116.2399)],width:3)
            }
        }.aspectRatio(1,contentMode:.fit).accessibilityHidden(true)
    }
}

struct PLSWordmark: View {
    var compact = false
    var body: some View {
        VStack(alignment:.leading,spacing:1) {
            Text("PLS").font(.system(size:compact ? 21:25,weight:.semibold,design:.rounded)).tracking(3)
            if !compact {
                Text("PLOIT LINK SATELLITE").font(.system(size:8,weight:.medium)).tracking(1.2).opacity(0.6)
            }
        }.accessibilityElement(children:.ignore).accessibilityLabel("Ploit Link Satellite")
    }
}
