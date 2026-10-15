import SwiftUI

/// Exact outlines from design/brand/source/cuekeeper-mark-forest.svg, without its export padding.
struct CuekeeperMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x:66,y:351)); p.addCurve(to: CGPoint(x:47,y:320), control1: CGPoint(x:54,y:348), control2: CGPoint(x:49,y:337))
        p.addLine(to: CGPoint(x:0,y:93)); p.addCurve(to: CGPoint(x:32,y:42), control1: CGPoint(x:-6,y:67), control2: CGPoint(x:7,y:49))
        p.addLine(to: CGPoint(x:209,y:1)); p.addCurve(to: CGPoint(x:267,y:37), control1: CGPoint(x:237,y:-6), control2: CGPoint(x:260,y:10))
        p.addLine(to: CGPoint(x:274,y:65)); p.addLine(to: CGPoint(x:137,y:65)); p.addCurve(to: CGPoint(x:66,y:135), control1: CGPoint(x:95,y:65), control2: CGPoint(x:66,y:94)); p.closeSubpath()
        p.move(to: CGPoint(x:137,y:85)); p.addLine(to: CGPoint(x:333,y:85)); p.addCurve(to: CGPoint(x:383,y:135), control1: CGPoint(x:362,y:85), control2: CGPoint(x:383,y:106)); p.addLine(to: CGPoint(x:383,y:419)); p.addCurve(to: CGPoint(x:355,y:437), control1: CGPoint(x:383,y:439), control2: CGPoint(x:370,y:448)); p.addLine(to: CGPoint(x:243,y:355)); p.addQuadCurve(to: CGPoint(x:227,y:355), control: CGPoint(x:235,y:349)); p.addLine(to: CGPoint(x:113,y:437)); p.addCurve(to: CGPoint(x:86,y:421), control1: CGPoint(x:97,y:449), control2: CGPoint(x:86,y:438)); p.addLine(to: CGPoint(x:86,y:136)); p.addCurve(to: CGPoint(x:137,y:85), control1: CGPoint(x:86,y:106), control2: CGPoint(x:107,y:85)); p.closeSubpath()
        p.addRoundedRect(in: CGRect(x:144,y:200,width:183,height:40), cornerSize: CGSize(width:20,height:20))
        return p.applying(CGAffineTransform(scaleX: rect.width / 383, y: rect.height / 448))
    }
}
