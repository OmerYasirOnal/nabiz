import AppKit
// App Store ekran görüntüsü üreticisi (yalnız geliştirme). storeshots.zsh derler; uygulamaya girmez.
// Örnek değerler gösterim içindir; arayüz gerçek Nabız görünümleridir.
let out=CommandLine.arguments[1]
_ = NSApplication.shared
func snapshot(_ view:NSView,dark:Bool,bg:NSColor?=nil)->NSBitmapImageRep {
    let host=NSView(frame:NSRect(origin:.zero,size:view.frame.size));host.wantsLayer=true
    host.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
    host.layer?.backgroundColor=(bg ?? (dark ? NSColor(white:0.17,alpha:1):NSColor(white:0.96,alpha:1))).cgColor
    host.layer?.cornerRadius=14
    view.frame=host.bounds;host.addSubview(view);host.layoutSubtreeIfNeeded()
    let rep=hires(host);view.removeFromSuperview();return rep
}
func hires(_ v:NSView)->NSBitmapImageRep {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(v.bounds.width*4),pixelsHigh:Int(v.bounds.height*4),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    rep.size=v.bounds.size;v.cacheDisplay(in:v.bounds,to:rep);return rep
}
func panelRep(_ vc:NSViewController,dark:Bool)->NSBitmapImageRep {
    let v=vc.view;v.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);v.frame=NSRect(origin:.zero,size:vc.preferredContentSize);return snapshot(v,dark:dark)
}
func windowRep(_ w:NSWindow,dark:Bool)->NSBitmapImageRep {
    w.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
    let v=w.contentView!;v.wantsLayer=true;v.layoutSubtreeIfNeeded()
    v.appearance=w.appearance
    v.effectiveAppearance.performAsCurrentDrawingAppearance{v.layer?.backgroundColor=NSColor.windowBackgroundColor.cgColor}
    v.layer?.cornerRadius=14
    return hires(v)
}
// 2880x1800 kompozisyon: koyu monitör zemini, üstte gerçek menü çubuğu öğeleri, solda başlık, sağda arayüz.
let W=2880,H=1800
func meterRep(_ meter:MenuMeter)->NSBitmapImageRep {
    meter.frame=NSRect(x:0,y:0,width:meter.preferredWidth,height:22);meter.appearance=NSAppearance(named:.darkAqua)
    return hires(meter)
}
func drawMenuBar(highlight:Int?) {
    let barH:CGFloat=78,y=CGFloat(H)-barH
    NSColor(white:0,alpha:0.42).setFill();NSRect(x:0,y:y,width:CGFloat(W),height:barH).fill()
    NSColor(white:1,alpha:0.06).setFill();NSRect(x:0,y:y,width:CGFloat(W),height:1.5).fill()
    let scale:CGFloat=3.2
    // Sağdan sola: saat, sistem simgeleri, Nabız ağ ve sistem öğeleri.
    let clock=NSAttributedString(string:"14:32",attributes:[.font:NSFont.systemFont(ofSize:40,weight:.medium),.foregroundColor:NSColor(white:1,alpha:0.92)])
    var x=CGFloat(W)-70-clock.size().width
    clock.draw(at:NSPoint(x:x,y:y+(barH-clock.size().height)/2))
    for name in ["battery.75percent","wifi"] {
        guard let img=NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:38,weight:.regular)) else {continue}
        let tinted=NSImage(size:img.size,flipped:false){r in img.draw(in:r);NSColor(white:1,alpha:0.92).set();r.fill(using:.sourceAtop);return true}
        x-=56+img.size.width;tinted.draw(at:NSPoint(x:x,y:y+(barH-img.size.height)/2),from:.zero,operation:.sourceOver,fraction:1)
    }
    x-=50
    for (i,meter) in [networkMeterShot,systemMeterShot].enumerated() {
        let rep=meterRep(meter),w=meter.preferredWidth*scale,h=22*scale
        x-=w+(i==0 ? 0:26)
        let r=NSRect(x:x,y:y+(barH-h)/2,width:w,height:h)
        if highlight==1-i {
            NSColor(white:1,alpha:0.16).setFill();NSBezierPath(roundedRect:r.insetBy(dx:-14,dy:2),xRadius:14,yRadius:14).fill()
        }
        rep.draw(in:r,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:false,hints:[.interpolation:NSImageInterpolation.high])
        if i==0 {networkX=r.midX} else {systemX=r.midX}
    }
}
var systemX:CGFloat=0,networkX:CGFloat=0
let systemMeterShot:MenuMeter={let m=MenuMeter();m.metric="38%";m.level=38;return m}()
let networkMeterShot:MenuMeter={let m=MenuMeter();m.section = .network;m.traffic=dominantTraffic(4_600_000,96_000);return m}()
func background() {
    let rect=NSRect(x:0,y:0,width:W,height:H)
    NSGradient(colors:[NSColor(srgbRed:0.075,green:0.105,blue:0.155,alpha:1),NSColor(srgbRed:0.02,green:0.027,blue:0.045,alpha:1)])!.draw(in:rect,angle:-90)
    for (c,center,r) in [(Vital.cpu,NSPoint(x:420,y:260),1300.0),(Vital.memory,NSPoint(x:2500,y:1400),1400.0)] {
        NSGradient(colors:[c.withAlphaComponent(0.16),c.withAlphaComponent(0)])!.draw(fromCenter:center,radius:0,toCenter:center,radius:CGFloat(r),options:[])
    }
    NSColor(white:1,alpha:0.028).setFill()
    var v:CGFloat=0;while v<CGFloat(W) {NSRect(x:v,y:0,width:1.5,height:CGFloat(H)).fill();v+=120}
    v=0;while v<CGFloat(H) {NSRect(x:0,y:v,width:CGFloat(W),height:1.5).fill();v+=120}
}
func drawText(_ title:String,_ subtitle:String,in box:NSRect,center:Bool) {
    let para=NSMutableParagraphStyle();para.alignment=center ? .center:.left;para.lineHeightMultiple=0.95
    // Üst etiket: logo + NABIZ
    let mark=NabizMark.image(size:64)
    let eyebrow=NSAttributedString(string:"NABIZ",attributes:[.font:NSFont.systemFont(ofSize:36,weight:.heavy),.kern:6,.foregroundColor:NSColor(white:1,alpha:0.75)])
    let ew=64+18+eyebrow.size().width
    let ex=center ? box.midX-ew/2:box.minX
    let titleText=NSAttributedString(string:title,attributes:[.font:NSFont.systemFont(ofSize:center ? 96:104,weight:.bold),.foregroundColor:NSColor.white,.paragraphStyle:para,.kern:-1.5])
    let subText=NSAttributedString(string:subtitle,attributes:[.font:NSFont.systemFont(ofSize:44,weight:.regular),.foregroundColor:NSColor(white:1,alpha:0.64),.paragraphStyle:para])
    let tH=titleText.boundingRect(with:NSSize(width:box.width,height:1000),options:[.usesLineFragmentOrigin]).height
    let sH=subText.boundingRect(with:NSSize(width:box.width,height:1000),options:[.usesLineFragmentOrigin]).height
    let total=64+44+tH+36+sH
    var y=box.midY+total/2
    y-=64;mark.draw(in:NSRect(x:ex,y:y,width:64,height:64));eyebrow.draw(at:NSPoint(x:ex+82,y:y+(64-eyebrow.size().height)/2))
    y-=44+tH;titleText.draw(with:NSRect(x:box.minX,y:y,width:box.width,height:tH),options:[.usesLineFragmentOrigin])
    y-=36+sH;subText.draw(with:NSRect(x:box.minX,y:y,width:box.width,height:sH),options:[.usesLineFragmentOrigin])
}
func place(_ images:[NSBitmapImageRep],in box:NSRect,gap:CGFloat=110,anchorTop:Bool=false) {
    var sizes=images.map{NSSize(width:CGFloat($0.pixelsWide)/4,height:CGFloat($0.pixelsHigh)/4)}
    var k=box.height/(sizes.map{$0.height}.max() ?? 1)
    let gaps=gap*CGFloat(max(0,sizes.count-1))
    let width=sizes.reduce(0){$0+$1.width}*k+gaps
    if width>box.width {k*=(box.width-gaps)/(width-gaps)}
    sizes=sizes.map{NSSize(width:$0.width*k,height:$0.height*k)}
    let total=sizes.reduce(0){$0+$1.width}+gaps
    var x=box.midX-total/2
    for (i,img) in images.enumerated() {
        let s=sizes[i],y=anchorTop ? box.maxY-s.height:box.midY-s.height/2
        let shadow=NSShadow();shadow.shadowBlurRadius=90;shadow.shadowOffset=NSSize(width:0,height:-30);shadow.shadowColor=NSColor(white:0,alpha:0.7)
        NSGraphicsContext.saveGraphicsState();shadow.set()
        img.draw(in:NSRect(x:x,y:y,width:s.width,height:s.height),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:false,hints:[.interpolation:NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        x+=s.width+gap
    }
}
/// layout: .side (metin solda, arayüz sağda) veya .stack (metin üstte, arayüzler altta yan yana).
enum Layout {case side,stack,bare}
func compose(_ name:String,title:String,subtitle:String,images:[NSBitmapImageRep],layout:Layout = .side,menuHighlight:Int?=nil) {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:W,pixelsHigh:H,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
    background();drawMenuBar(highlight:menuHighlight)
    switch layout {
    case .side:
        drawText(title,subtitle,in:NSRect(x:190,y:120,width:1040,height:CGFloat(H)-260),center:false)
        place(images,in:NSRect(x:1340,y:110,width:1400,height:CGFloat(H)-260),anchorTop:menuHighlight != nil)
    case .bare:
        place(images,in:NSRect(x:160,y:90,width:CGFloat(W)-320,height:CGFloat(H)-230),gap:90,anchorTop:true)
    case .stack:
        drawText(title,subtitle,in:NSRect(x:300,y:CGFloat(H)-560,width:CGFloat(W)-600,height:420),center:true)
        place(images,in:NSRect(x:200,y:100,width:CGFloat(W)-400,height:CGFloat(H)-720),anchorTop:true)
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"\(out)/\(name).png"))
}
let base=Snapshot(cpu:38,gpu:21,memoryValid:true,ramUsed:15.4*1073741824,ramTotal:24*1073741824,compressed:2.1*1073741824,swap:0.1*1073741824,pressure:1,temperature:nil,fans:[],diskFree:644.2*1073741824,download:4_600_000,upload:96_000,today:Traffic(received:3_400_000_000,sent:212_000_000),week:Traffic(received:18_900_000_000,sent:1_240_000_000),cpuUser:27,cpuSystem:11,sensors:false,liveApps:[AppLoad(name:"Xcode",cpu:142),AppLoad(name:"Safari",cpu:31),AppLoad(name:"Music",cpu:9)],storageError:nil,date:Date())
var traces=Traces()
for i in 0..<60 {
    let w=sin(Double(i)/5)*0.5+0.5,n=Double((i*37)%11)/11
    var t=base;t.cpu=18+w*22+n*8+(i>46 ? 14:0);t.gpu=10+w*14+n*4;t.ramUsed=(14.8+Double(i)/100)*1073741824
    t.download=400_000+w*1_800_000+(i>44 ? 2_600_000:0)+n*300_000;t.upload=40_000+w*50_000+n*20_000
    traces.add(t)
}
let s=base
func rep2x(_ make:()->NSBitmapImageRep)->NSBitmapImageRep { make() } // ekran 2x olduğundan cacheDisplay zaten 2x üretir
let sys=SystemPanel();_ = sys.view;sys.update(s,traces:traces)
let net=NetworkPanel();_ = net.view;net.update(s,traces:traces)
let settings=SettingsController()
var hist=HistorySummary();hist.hourly=true;hist.minutes=600
let cal=Calendar.current;let dayStart=cal.startOfDay(for:Date())
for h in 0..<24 {
    var b=HistoryBucket(start:cal.date(byAdding:.hour,value:h,to:dayStart)!)
    if h>=8 && h<=19 { b.seconds=Double(3000+(h*331)%600); b.high=h>=13 && h<=16 ? Double(400+(h*97)%700):0 }
    hist.buckets.append(b);hist.seconds+=b.seconds;hist.highSeconds+=b.high
}
hist.busiest="14:00–15:00";hist.traffic=Traffic(received:3_400_000_000,sent:212_000_000)
hist.applications=[AppLoad(name:"Xcode",cpu:168),AppLoad(name:"Final Cut Pro",cpu:121),AppLoad(name:"Safari",cpu:44),AppLoad(name:"Music",cpu:12)]
let history=HistoryController();history.display(hist,recording:true)
compose("01",title:L("Mac'inizin nabzı, menü çubuğunda","Your Mac's pulse, in the menu bar"),subtitle:L("İşlemci, bellek, GPU ve ısı tek bakışta, canlı grafiklerle.","CPU, memory, GPU and thermal state at a glance, with live graphs."),images:[panelRep(sys,dark:true)],menuHighlight:0)
compose("02",title:L("İndirme ve gönderme, ayrı ayrı","Download and upload, side by side"),subtitle:L("Canlı hız grafiği, bugün ve son 7 günün trafiği.","A live speed graph plus today's and the last 7 days' traffic."),images:[panelRep(net,dark:true)],menuHighlight:1)
compose("03",title:L("İki öğe, iki panel","Two items, two panels"),subtitle:L("Menü çubuğunda az yer kaplar; her öğe kendi panelini açar.","Takes little menu bar space; each item opens its own panel."),images:[panelRep(sys,dark:true),panelRep(net,dark:true)],layout:.stack)
compose("04",title:L("Mac'iniz ne zaman zorlandı?","When did your Mac work hardest?"),subtitle:L("İsteğe bağlı 14 günlük geçmiş, yalnız bu Mac'te saklanır.","Optional 14-day history, stored only on this Mac."),images:[windowRep(history.window!,dark:true)])
compose("05",title:L("Sade ve sizin için ayarlı","Simple, and set up your way"),subtitle:L("Gösterge, uyarı eşiği ve yenileme aralığı. Veri toplama yok.","Display, alert threshold and refresh rate. No data collection."),images:[windowRep(settings.window!,dark:true)])
compose("hero",title:"",subtitle:"",images:[panelRep(sys,dark:true),panelRep(net,dark:true)],layout:.bare,menuHighlight:0)
print("ok")
