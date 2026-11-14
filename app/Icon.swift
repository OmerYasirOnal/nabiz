// Nabız uygulama simgesi (1.6): koyu monitör ekranında parlayan nabız çizgisi "N" harfini çizer.
// Geometri Panels.swift içindeki NabizMark ile aynıdır.
// Yalnız derleme sırasında çalışır: `Icon <iconset klasörü>` PNG boyutlarını üretir, iconutil .icns'e çevirir.
import AppKit

func color(_ hex:UInt32,_ alpha:CGFloat=1)->CGColor {
    CGColor(srgbRed:CGFloat(hex>>16&0xff)/255,green:CGFloat(hex>>8&0xff)/255,blue:CGFloat(hex&0xff)/255,alpha:alpha)
}

func drawIcon(_ c:CGContext,size:CGFloat) {
    let s=size/1024
    c.scaleBy(x:s,y:s)
    // Tasarım koordinatları üstten aşağı; Core Graphics alttan yukarı.
    c.translateBy(x:0,y:1024);c.scaleBy(x:1,y:-1)
    let space=CGColorSpace(name:CGColorSpace.sRGB)!
    let body=CGPath(roundedRect:CGRect(x:100,y:100,width:824,height:824),cornerWidth:185,cornerHeight:185,transform:nil)
    c.saveGState();c.addPath(body);c.clip()
    // Zemin: derin lacivert-siyah, ortada hafif yeşil-mavi ışıma.
    let bg=CGGradient(colorsSpace:space,colors:[color(0x16202C),color(0x05070B)] as CFArray,locations:[0,1])!
    c.drawLinearGradient(bg,start:CGPoint(x:512,y:100),end:CGPoint(x:512,y:924),options:[])
    let halo=CGGradient(colorsSpace:space,colors:[color(0x3DF5A0,0.22),color(0x4CC9FF,0.08),color(0x4CC9FF,0)] as CFArray,locations:[0,0.45,1])!
    c.drawRadialGradient(halo,startCenter:CGPoint(x:512,y:520),startRadius:0,endCenter:CGPoint(x:512,y:520),endRadius:420,options:[])
    // Monitör ızgarası (küçük boyutlarda çizilmez).
    if size>=128 {
        c.setStrokeColor(color(0xFFFFFF,0.045));c.setLineWidth(3)
        var v:CGFloat=100+824/8
        while v<924 {c.move(to:CGPoint(x:v,y:100));c.addLine(to:CGPoint(x:v,y:924));c.move(to:CGPoint(x:100,y:v));c.addLine(to:CGPoint(x:924,y:v));v+=824/8}
        c.strokePath()
    }
    let points:[CGPoint]=[.init(x:150,y:560),.init(x:300,y:560),.init(x:370,y:300),.init(x:600,y:720),.init(x:670,y:300),.init(x:740,y:560),.init(x:874,y:560)]
    let pulse=CGMutablePath();pulse.addLines(between:points)
    // Küçük boyutlarda çizgi kaybolmasın diye kalınlaşır.
    let width:CGFloat=size<=32 ? 96:(size<=64 ? 80:62)
    let stroke=pulse.copy(strokingWithWidth:width,lineCap:.round,lineJoin:.round,miterLimit:10)
    // Işıma: aynı çizgi bulanık gölgeyle.
    c.saveGState()
    c.setShadow(offset:.zero,blur:size<=64 ? 0:70,color:color(0x3DF5A0,0.85))
    c.addPath(stroke);c.setFillColor(color(0x3DF5A0,size<=64 ? 0:0.55));c.fillPath()
    c.restoreGState()
    c.saveGState();c.addPath(stroke);c.clip()
    let line=CGGradient(colorsSpace:space,colors:[color(0x3DF5A0,0.35),color(0x3DF5A0),color(0x4CC9FF),color(0x4CC9FF,0.35)] as CFArray,locations:[0,0.25,0.75,1])!
    c.drawLinearGradient(line,start:CGPoint(x:150,y:0),end:CGPoint(x:874,y:0),options:[])
    c.restoreGState()
    // Parlak uç noktası: sağ zirvede canlı ölçüm imleci.
    let dot:CGFloat=size<=32 ? 0:30
    if dot>0 {
        c.saveGState();c.setShadow(offset:.zero,blur:40,color:color(0xFFFFFF,0.9))
        c.setFillColor(color(0xF2FFFB));c.fillEllipse(in:CGRect(x:670-dot,y:300-dot,width:dot*2,height:dot*2));c.restoreGState()
    }
    c.restoreGState()
    c.addPath(body.copy(strokingWithWidth:4,lineCap:.butt,lineJoin:.miter,miterLimit:10))
    c.setFillColor(color(0xFFFFFF,0.10));c.fillPath()
}

let arguments=CommandLine.arguments
guard arguments.count==2 else {fputs("kullanım: Icon <Nabiz.iconset>\n",stderr);exit(2)}
let folder=URL(fileURLWithPath:arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for (points,scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels=points*scale
    let context=CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high;context.setShouldAntialias(true)
    drawIcon(context,size:CGFloat(pixels))
    let rep=NSBitmapImageRep(cgImage:context.makeImage()!)
    let name=scale==1 ? "icon_\(points)x\(points).png":"icon_\(points)x\(points)@2x.png"
    try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent(name))
}
