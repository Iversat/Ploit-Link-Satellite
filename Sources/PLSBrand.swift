import SwiftUI

// The open orbital paths and the P monogram share the app icon's normalized geometry.
struct PLSGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                PLSOrbitShape().stroke(style:StrokeStyle(lineWidth:2.5,lineCap:.round,lineJoin:.round))
                PLSMonogramShape().stroke(style:StrokeStyle(lineWidth:7,lineCap:.round,lineJoin:.round))
                Circle().frame(width:7.4,height:7.4).position(x:82,y:55)
            }
            .frame(width:100,height:100)
            .scaleEffect(side / 100)
            .frame(width:geometry.size.width,height:geometry.size.height)
        }
        .aspectRatio(1,contentMode:.fit)
        .accessibilityHidden(true)
    }
}

private struct PLSMonogramShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to:CGPoint(x:34,y:73))
        path.addLine(to:CGPoint(x:34,y:27))
        path.addLine(to:CGPoint(x:56,y:27))
        path.addCurve(to:CGPoint(x:56,y:55),control1:CGPoint(x:76,y:27),control2:CGPoint(x:76,y:55))
        path.addLine(to:CGPoint(x:34,y:55))
        return path.applying(CGAffineTransform(scaleX:rect.width/100,y:rect.height/100))
    }
}

private struct PLSOrbitShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to:CGPoint(x:18,y:60))
        path.addCurve(to:CGPoint(x:77,y:21),control1:CGPoint(x:21,y:31),control2:CGPoint(x:52,y:12))
        path.addCurve(to:CGPoint(x:82,y:55),control1:CGPoint(x:91,y:26),control2:CGPoint(x:92,y:40))
        path.move(to:CGPoint(x:79,y:61))
        path.addCurve(to:CGPoint(x:18,y:78),control1:CGPoint(x:61,y:86),control2:CGPoint(x:32,y:91))
        path.addCurve(to:CGPoint(x:18,y:60),control1:CGPoint(x:13,y:73),control2:CGPoint(x:13,y:67))
        return path.applying(CGAffineTransform(scaleX:rect.width/100,y:rect.height/100))
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
