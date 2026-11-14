import AppKit

// Menü çubuğu öğeleri (1.6): iki satır yerine büyük, yuvarlak rakam ve altında ince bir gösterge.
// Genişlik en geniş olası değere göre bir kez hesaplanır; rakamlar değişince öğe kaymaz.
final class MenuMeter: NSView {
    enum Section { case metric, network }
    var section:Section = .metric
    var mode=0 {didSet{if oldValue != mode {needsDisplay=true}}}
    var metric="—" {didSet{if oldValue != metric {needsDisplay=true}}}
    /// 0...100; sistem öğesinin altındaki ince çubuğu doldurur.
    var level:Double? {didSet{if oldValue != level {needsDisplay=true}}}
    var traffic="—" {didSet{if oldValue != traffic {needsDisplay=true}}}
    var paused=false {didSet{if oldValue != paused {needsDisplay=true}}}
    /// Eşik aşıldığında değer ve çubuk turuncu çizilir (Ayarlar › Yüksek CPU'da vurgula).
    var alert=false {didSet{if oldValue != alert {needsDisplay=true}}}

    private static func rounded(_ size:CGFloat,_ weight:NSFont.Weight)->NSFont {
        let base=NSFont.monospacedDigitSystemFont(ofSize:size,weight:weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap{NSFont(descriptor:$0,size:size)} ?? base
    }
    private static let valueFont=rounded(12,.semibold)
    private static let percentFont=rounded(8.5,.semibold)
    private static let unitFont=NSFont.systemFont(ofSize:7.5,weight:.semibold)
    private static func width(_ s:String,_ f:NSFont)->CGFloat {ceil(NSAttributedString(string:s,attributes:[.font:f]).size().width)}
    private static let metricWidth=width("100",valueFont)+width("%",percentFont)+3
    private static let networkWidth=max(width("99.9",valueFont),width("↓ MB/s",unitFont))+4
    var preferredWidth:CGFloat { section == .network ? Self.networkWidth : (mode==2 || paused ? 16:Self.metricWidth) }

    override func hitTest(_ point:NSPoint)->NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { needsDisplay=true }

    override func draw(_ dirtyRect:NSRect) {
        let foreground=NSColor.labelColor
        let secondary=foreground.withAlphaComponent(0.6)
        let offset=(bounds.height-22)/2
        if section == .metric {
            if paused { drawPause(color:secondary,offset:offset); return }
            if mode==2 { drawPulse(color:foreground,offset:offset); return }
            let tint:NSColor=alert ? .systemOrange:foreground
            // Rakam ve küçük yüzde işareti tek parça ortalanır.
            let number=metric.replacingOccurrences(of:"%",with:"")
            let line=NSMutableAttributedString(string:number,attributes:[.font:Self.valueFont,.foregroundColor:tint])
            if number != "—" {line.append(NSAttributedString(string:"%",attributes:[.font:Self.percentFont,.foregroundColor:tint.withAlphaComponent(0.75)]))}
            let size=line.size()
            line.draw(at:NSPoint(x:(bounds.width-size.width)/2,y:offset+7.5+Self.valueFont.descender))
            // İnce gösterge: RAM modunda dört bölmeli, CPU modunda düz.
            let track=NSRect(x:3,y:offset+3,width:bounds.width-6,height:2.5)
            foreground.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect:track,xRadius:1.25,yRadius:1.25).fill()
            if let level {
                var fill=track;fill.size.width=max(track.height,track.width*CGFloat(min(100,max(0,level)))/100)
                tint.setFill();NSBezierPath(roundedRect:fill,xRadius:1.25,yRadius:1.25).fill()
            }
            if mode==1 {
                NSColor.clear.setFill()
                NSGraphicsContext.current?.compositingOperation = .clear
                for i in 1..<4 {NSRect(x:track.minX+track.width*CGFloat(i)/4-0.5,y:track.minY,width:1,height:track.height).fill()}
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return
        }
        let valueColor=paused ? secondary:foreground
        let parts=traffic.split(separator:" ",maxSplits:1).map(String.init)
        let direction=parts.count==2 ? parts[0]:""
        let amount=parts.count==2 ? parts[1]:traffic
        let unitStart=amount.firstIndex(where:{$0.isLetter}) ?? amount.endIndex
        let number=String(amount[..<unitStart]),unit=String(amount[unitStart...])
        centered(number,font:Self.valueFont,color:valueColor,baseline:offset+8.5)
        centered([direction,unit].filter{!$0.isEmpty}.joined(separator:" "),font:Self.unitFont,color:secondary,baseline:offset+1.5)
    }

    private func centered(_ value:String,font:NSFont,color:NSColor,baseline:CGFloat) {
        let line=NSAttributedString(string:value,attributes:[.font:font,.foregroundColor:color])
        line.draw(at:NSPoint(x:(bounds.width-line.size().width)/2,y:baseline+font.descender))
    }
    /// Kısa mod: Nabız logosundaki nabız çizgisi, menü çubuğu renginde.
    private func drawPulse(color:NSColor,offset:CGFloat) {
        let path=NSBezierPath()
        let s=bounds.width/1024*0.98,x0=(bounds.width-1024*s)/2
        for (i,p) in NabizMark.points.enumerated() {
            let point=NSPoint(x:x0+p.x*s,y:offset+11+(512-p.y)*s)
            i==0 ? path.move(to:point):path.line(to:point)
        }
        path.lineWidth=1.6;path.lineCapStyle = .round;path.lineJoinStyle = .round
        color.setStroke();path.stroke()
    }
    private func drawPause(color:NSColor,offset:CGFloat) {
        color.setFill()
        let mid=bounds.width/2
        for x in [mid-3.5,mid+1] {NSBezierPath(roundedRect:NSRect(x:x,y:offset+6,width:2.5,height:10),xRadius:1.25,yRadius:1.25).fill()}
    }
}
