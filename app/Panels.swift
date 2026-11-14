import AppKit
import QuartzCore

// Nabız 1.6 panelleri: "yaşam belirtileri monitörü". Paneller her zaman koyu, ince ızgaralı bir monitör
// ekranıdır; her ölçü kendi parlayan rengi ve canlı iz çizgisiyle gösterilir.

enum Vital {
    static let cpu=NSColor(srgbRed:0.24,green:0.96,blue:0.63,alpha:1)
    static let memory=NSColor(srgbRed:0.30,green:0.79,blue:1.00,alpha:1)
    static let gpu=NSColor(srgbRed:0.72,green:0.55,blue:1.00,alpha:1)
    static let heat=NSColor(srgbRed:1.00,green:0.71,blue:0.28,alpha:1)
    static let down=NSColor(srgbRed:0.30,green:0.79,blue:1.00,alpha:1)
    static let up=NSColor(srgbRed:1.00,green:0.48,blue:0.35,alpha:1)
    static let alert=NSColor(srgbRed:1.00,green:0.36,blue:0.30,alpha:1)
    static let text=NSColor(white:0.96,alpha:1)
    static let dim=NSColor(white:1,alpha:0.58)
    static let faint=NSColor(white:1,alpha:0.34)
    static let surface=NSColor(white:1,alpha:0.045)
    static let line=NSColor(white:1,alpha:0.08)
}

/// Panellerin ortak eylemleri. AppDelegate bağlar; paneller yalnız gösterir.
struct PanelActions {
    var history:()->Void={}
    var settings:()->Void={}
    var pause:()->Void={}
    var quit:()->Void={}
}

/// Sabit kapasiteli, yalnız bellekte tutulan ölçüm izi.
struct Series {
    static let capacity=60
    private(set) var values:[Double]=[]
    mutating func add(_ value:Double?) {
        guard let value,value.isFinite else {return}
        values.append(value);if values.count>Self.capacity {values.removeFirst(values.count-Self.capacity)}
    }
    mutating func clear(){values=[]}
    var max:Double? {values.max()}
    var average:Double? {values.isEmpty ? nil:values.reduce(0,+)/Double(values.count)}
}

/// Panel kapalıyken de dolan son ölçümler (yalnız bellekte; diske yazılmaz).
struct Traces {
    var cpu=Series(),memory=Series(),gpu=Series(),heat=Series(),down=Series(),up=Series()
    private(set) var peakDown:Double?,peakUp:Double?
    mutating func add(_ s:Snapshot) {
        cpu.add(s.cpu);gpu.add(s.gpu)
        memory.add(s.memoryValid && s.ramTotal>0 ? s.ramUsed/s.ramTotal*100:nil)
        heat.add(s.sensors ? s.temperature:Double(thermalLevel()+1)*25)
        if let d=s.download,let u=s.upload,d.isFinite,u.isFinite {
            down.add(Swift.max(0,d));up.add(Swift.max(0,u))
            peakDown=Swift.max(peakDown ?? 0,d);peakUp=Swift.max(peakUp ?? 0,u)
        }
    }
    mutating func clear(){cpu.clear();memory.clear();gpu.clear();heat.clear();down.clear();up.clear()}
}

/// Koyu monitör zemini: hafif dikey geçiş + ince ızgara.
final class MonitorBackground: NSView {
    override var isFlipped:Bool {true}
    override func draw(_ dirtyRect:NSRect) {
        NSGradient(colors:[NSColor(srgbRed:0.075,green:0.09,blue:0.12,alpha:1),NSColor(srgbRed:0.035,green:0.04,blue:0.055,alpha:1)])!.draw(in:bounds,angle:90)
        let grid=NSBezierPath();let step:CGFloat=18
        var x=step;while x<bounds.width {grid.move(to:NSPoint(x:x,y:0));grid.line(to:NSPoint(x:x,y:bounds.height));x+=step}
        var y=step;while y<bounds.height {grid.move(to:NSPoint(x:0,y:y));grid.line(to:NSPoint(x:bounds.width,y:y));y+=step}
        NSColor(white:1,alpha:0.022).setStroke();grid.lineWidth=1;grid.stroke()
    }
}

/// Canlı iz: parlayan çizgi ve altında solan dolgu. `mirror` verilirse ikinci seri eksenin altına çizilir.
final class TraceView: NSView {
    var values:[Double]=[] {didSet{needsDisplay=true}}
    var mirror:[Double]?=nil {didSet{needsDisplay=true}}
    var color:NSColor=Vital.cpu {didSet{needsDisplay=true}}
    var mirrorColor:NSColor=Vital.up
    /// Sabit üst sınır (yüzdeler için 100). nil ise görünen en yüksek değere göre ölçeklenir.
    var ceiling:Double?=100
    var floorValue:Double=1
    var grid=false
    var lineWidth:CGFloat=1.6
    override var isFlipped:Bool {false}
    override func draw(_ dirtyRect:NSRect) {
        let rect=bounds.insetBy(dx:0,dy:3)
        if grid {
            let path=NSBezierPath()
            for i in 1..<4 {let y=rect.minY+rect.height*CGFloat(i)/4;path.move(to:NSPoint(x:rect.minX,y:y));path.line(to:NSPoint(x:rect.maxX,y:y))}
            NSColor(white:1,alpha:0.05).setStroke();path.lineWidth=1;path.stroke()
        }
        if let mirror {
            let mid=rect.midY
            NSColor(white:1,alpha:0.14).setStroke();let axis=NSBezierPath();axis.move(to:NSPoint(x:rect.minX,y:mid));axis.line(to:NSPoint(x:rect.maxX,y:mid));axis.lineWidth=1;axis.stroke()
            plot(values,in:NSRect(x:rect.minX,y:mid+1,width:rect.width,height:rect.height/2-1),color:color,flip:false)
            plot(mirror,in:NSRect(x:rect.minX,y:rect.minY,width:rect.width,height:rect.height/2-1),color:mirrorColor,flip:true)
        } else {
            plot(values,in:rect,color:color,flip:false)
        }
    }
    private func plot(_ data:[Double],in rect:NSRect,color:NSColor,flip:Bool) {
        guard data.count>1 else {return}
        let top=ceiling ?? Swift.max(floorValue,(data.max() ?? 0)*1.15)
        let step=rect.width/CGFloat(Series.capacity-1)
        let start=rect.maxX-step*CGFloat(data.count-1)
        func point(_ i:Int)->NSPoint {
            let f=CGFloat(Swift.min(1,Swift.max(0,data[i]/top)))
            return NSPoint(x:start+step*CGFloat(i),y:flip ? rect.maxY-rect.height*f:rect.minY+rect.height*f)
        }
        let line=NSBezierPath();line.move(to:point(0))
        for i in 1..<data.count {
            let a=point(i-1),b=point(i),mid=(a.x+b.x)/2
            line.curve(to:b,controlPoint1:NSPoint(x:mid,y:a.y),controlPoint2:NSPoint(x:mid,y:b.y))
        }
        let area=line.copy() as! NSBezierPath
        let base=flip ? rect.maxY:rect.minY
        area.line(to:NSPoint(x:rect.maxX,y:base));area.line(to:NSPoint(x:start,y:base));area.close()
        NSGraphicsContext.saveGraphicsState();area.addClip()
        NSGradient(colors:[color.withAlphaComponent(0.0),color.withAlphaComponent(0.32)])!.draw(in:rect,angle:flip ? -90:90)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        let glow=NSShadow();glow.shadowColor=color.withAlphaComponent(0.85);glow.shadowBlurRadius=6;glow.set()
        color.setStroke();line.lineWidth=lineWidth;line.lineCapStyle = .round;line.lineJoinStyle = .round;line.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let last=point(data.count-1)
        NSGraphicsContext.saveGraphicsState()
        let dotGlow=NSShadow();dotGlow.shadowColor=color;dotGlow.shadowBlurRadius=8;dotGlow.set()
        color.setFill();NSBezierPath(ovalIn:NSRect(x:last.x-2.5,y:last.y-2.5,width:5,height:5)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

func glowLabel(_ text:String,size:CGFloat,weight:NSFont.Weight = .semibold,color:NSColor=Vital.text,mono:Bool=true)->NSTextField {
    let label=NSTextField(labelWithString:text)
    label.font=mono ? .monospacedDigitSystemFont(ofSize:size,weight:weight):.systemFont(ofSize:size,weight:weight)
    label.textColor=color;label.wantsLayer=true
    label.layer?.shadowColor=color.cgColor;label.layer?.shadowRadius=size>20 ? 10:5;label.layer?.shadowOpacity=0.45;label.layer?.shadowOffset = .zero
    return label
}
func setGlow(_ label:NSTextField,_ color:NSColor){label.textColor=color;label.layer?.shadowColor=color.cgColor}
func caps(_ text:String,color:NSColor=Vital.dim)->NSTextField {
    let label=NSTextField(labelWithString:text)
    label.attributedStringValue=NSAttributedString(string:text,attributes:[.kern:1.1,.font:NSFont.systemFont(ofSize:9.5,weight:.bold),.foregroundColor:color])
    // Harf aralığı ölçülen genişliği biraz aşar; son kelime alt satıra kaymasın.
    label.cell?.wraps=false;label.lineBreakMode = .byClipping;label.maximumNumberOfLines=1
    label.widthAnchor.constraint(greaterThanOrEqualToConstant:ceil(label.intrinsicContentSize.width+2)).isActive=true
    return label
}

/// Yuvarlatılmış yarı saydam yüzey.
final class Surface: NSView {
    init(radius:CGFloat=12){super.init(frame:.zero);wantsLayer=true;translatesAutoresizingMaskIntoConstraints=false
        layer?.cornerRadius=radius;layer?.backgroundColor=Vital.surface.cgColor;layer?.borderWidth=1;layer?.borderColor=Vital.line.cgColor}
    required init?(coder:NSCoder){fatalError()}
}

/// Küçük ölçü kutusu: renkli başlık, parlayan değer, alt metin ve mini iz.
final class VitalTile: NSView {
    let title:NSTextField
    let value:NSTextField
    let detail=NSTextField(labelWithString:"")
    let trace=TraceView()
    private(set) var color:NSColor
    init(_ name:String,color:NSColor,width:CGFloat) {
        self.color=color
        title=caps(name,color:color.withAlphaComponent(0.9))
        value=glowLabel("—",size:22,color:color)
        super.init(frame:.zero)
        translatesAutoresizingMaskIntoConstraints=false
        let surface=Surface();addSubview(surface)
        detail.font = .systemFont(ofSize:10);detail.textColor=Vital.dim;detail.lineBreakMode = .byTruncatingTail
        trace.color=color;trace.lineWidth=1.3;trace.translatesAutoresizingMaskIntoConstraints=false
        let stack=NSStackView(views:[title,value,detail,trace]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=3
        stack.setCustomSpacing(6,after:detail)
        stack.translatesAutoresizingMaskIntoConstraints=false;addSubview(stack)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo:leadingAnchor),surface.trailingAnchor.constraint(equalTo:trailingAnchor),surface.topAnchor.constraint(equalTo:topAnchor),surface.bottomAnchor.constraint(equalTo:bottomAnchor),
            widthAnchor.constraint(equalToConstant:width),
            stack.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10),stack.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),
            stack.topAnchor.constraint(equalTo:topAnchor,constant:9),stack.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-8),
            trace.heightAnchor.constraint(equalToConstant:22),trace.widthAnchor.constraint(equalToConstant:width-20),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant:width-20)])
        setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel(name)
    }
    required init?(coder:NSCoder){fatalError()}
    func set(_ text:String,_ sub:String,trace data:[Double],ceiling:Double?=100,color override:NSColor?=nil) {
        let tint=override ?? color
        value.stringValue=text;setGlow(value,tint);detail.stringValue=sub
        trace.color=tint;trace.ceiling=ceiling;trace.values=data
        setAccessibilityValue("\(text), \(sub)")
    }
}

/// Başlıktaki canlı göstergesi: yanıp sönen nokta + durum.
final class LiveBadge: NSView {
    private let dot=NSView(),label=NSTextField(labelWithString:"")
    init() {
        super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false
        setContentHuggingPriority(.required,for:.horizontal)
        wantsLayer=true;layer?.cornerRadius=10;layer?.backgroundColor=NSColor(white:1,alpha:0.06).cgColor
        dot.wantsLayer=true;dot.layer?.cornerRadius=3;dot.translatesAutoresizingMaskIntoConstraints=false
        label.translatesAutoresizingMaskIntoConstraints=false;label.setContentHuggingPriority(.required,for:.horizontal)
        addSubview(dot);addSubview(label)
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant:20),dot.widthAnchor.constraint(equalToConstant:6),dot.heightAnchor.constraint(equalToConstant:6),
            dot.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),dot.centerYAnchor.constraint(equalTo:centerYAnchor),
            label.leadingAnchor.constraint(equalTo:dot.trailingAnchor,constant:6),label.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-9),label.centerYAnchor.constraint(equalTo:centerYAnchor)])
    }
    required init?(coder:NSCoder){fatalError()}
    override var intrinsicContentSize:NSSize {NSSize(width:ceil(label.intrinsicContentSize.width)+31,height:20)}
    func set(_ text:String,color:NSColor,pulse:Bool,tip:String) {
        defer {invalidateIntrinsicContentSize()}
        label.attributedStringValue=NSAttributedString(string:text,attributes:[.kern:1.0,.font:NSFont.systemFont(ofSize:9.5,weight:.bold),.foregroundColor:color])
        dot.layer?.backgroundColor=color.cgColor;dot.layer?.shadowColor=color.cgColor;dot.layer?.shadowRadius=4;dot.layer?.shadowOpacity=0.9;dot.layer?.shadowOffset = .zero
        toolTip=tip
        if pulse {
            if dot.layer?.animation(forKey:"pulse")==nil {
                let a=CABasicAnimation(keyPath:"opacity");a.fromValue=1;a.toValue=0.25;a.duration=0.9;a.autoreverses=true;a.repeatCount = .infinity
                a.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut);dot.layer?.add(a,forKey:"pulse")
            }
        } else {dot.layer?.removeAnimation(forKey:"pulse")}
    }
}

/// Monitör stilinde düğme: yarı saydam hap, üzerine gelince aydınlanır.
final class PillButton: NSButton {
    private var hovering=false {didSet{needsDisplay=true}}
    init(title:String?=nil,symbol:String?=nil,tip:String,target:AnyObject?,action:Selector) {
        super.init(frame:.zero)
        self.target=target;self.action=action;isBordered=false;wantsLayer=true;translatesAutoresizingMaskIntoConstraints=false
        toolTip=tip;setAccessibilityLabel(tip);contentTintColor=Vital.text
        if let symbol {image=NSImage(systemSymbolName:symbol,accessibilityDescription:tip)?.withSymbolConfiguration(.init(pointSize:12,weight:.semibold));imagePosition = .imageOnly}
        attributedTitle=NSAttributedString(string:title ?? "",attributes:[.font:NSFont.systemFont(ofSize:11.5,weight:.semibold),.foregroundColor:Vital.text])
        heightAnchor.constraint(equalToConstant:28).isActive=true
        widthAnchor.constraint(greaterThanOrEqualToConstant:title==nil ? 32:0).isActive=true
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self))
    }
    required init?(coder:NSCoder){fatalError()}
    override var wantsUpdateLayer:Bool {true}
    override var intrinsicContentSize:NSSize { var s=super.intrinsicContentSize;s.width+=title.isEmpty ? 14:22;return s }
    override func updateLayer(){layer?.cornerRadius=8;layer?.backgroundColor=NSColor(white:1,alpha:hovering ? 0.14:0.07).cgColor}
    override func mouseEntered(with event:NSEvent){hovering=true}
    override func mouseExited(with event:NSEvent){hovering=false}
    func setSymbol(_ symbol:String,tip:String){image=NSImage(systemSymbolName:symbol,accessibilityDescription:tip)?.withSymbolConfiguration(.init(pointSize:12,weight:.semibold));toolTip=tip;setAccessibilityLabel(tip)}
}

/// Panellerde ortak iskelet: monitör zemini, başlık, canlı göstergesi, alt eylem çubuğu.
class BasePanel: NSViewController {
    static let width:CGFloat=336
    var actions=PanelActions()
    let content=NSStackView()
    /// Yalnız kayıt hatası gibi önemli durumlarda görünür.
    let footer=NSTextField(wrappingLabelWithString:"")
    private let badge=LiveBadge()
    private var pauseButton:PillButton?
    private var paused=false
    private var lastDate:Date?
    private let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    func makeView(title:String,subtitle:String) {
        let background=MonitorBackground();view=background
        background.appearance=NSAppearance(named:.darkAqua)
        let mark=NSImageView(image:NabizMark.image(size:24));mark.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant:24),mark.heightAnchor.constraint(equalToConstant:24)])
        let name=NSTextField(labelWithString:title);name.font = .systemFont(ofSize:15,weight:.bold);name.textColor=Vital.text
        let sub=NSTextField(labelWithString:subtitle);sub.font = .systemFont(ofSize:10.5,weight:.medium);sub.textColor=Vital.faint
        let titles=NSStackView(views:[name,sub]);titles.orientation = .vertical;titles.alignment = .leading;titles.spacing=0
        let heading=NSStackView(views:[mark,titles,NSView(),badge]);heading.orientation = .horizontal;heading.spacing=9;heading.alignment = .centerY
        heading.widthAnchor.constraint(equalToConstant:Self.width).isActive=true
        content.orientation = .vertical;content.alignment = .leading;content.spacing=10
        content.addArrangedSubview(heading);content.setCustomSpacing(14,after:heading)
        view.addSubview(content);content.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:16),content.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-16),content.topAnchor.constraint(equalTo:view.topAnchor,constant:16),content.bottomAnchor.constraint(equalTo:view.bottomAnchor,constant:-14)])
        setLive(nil)
    }
    func row(_ label:String,tip:String?=nil,dot:NSColor?=nil)->(NSView,NSTextField) {
        let title=NSTextField(labelWithString:label);title.font = .systemFont(ofSize:11.5);title.textColor=Vital.dim;title.lineBreakMode = .byTruncatingTail
        let value=NSTextField(labelWithString:"—");value.font = .monospacedDigitSystemFont(ofSize:11.5,weight:.semibold);value.textColor=Vital.text;value.alignment = .right
        value.toolTip=tip;title.toolTip=tip
        var views:[NSView]=[title,NSView(),value]
        if let dot {let d=NSView();d.wantsLayer=true;d.layer?.cornerRadius=2.5;d.layer?.backgroundColor=dot.cgColor;d.translatesAutoresizingMaskIntoConstraints=false
            NSLayoutConstraint.activate([d.widthAnchor.constraint(equalToConstant:5),d.heightAnchor.constraint(equalToConstant:5)]);views.insert(d,at:0)}
        let row=NSStackView(views:views);row.orientation = .horizontal;row.spacing=8;row.alignment = .centerY
        row.widthAnchor.constraint(equalToConstant:Self.width-24).isActive=true
        title.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return (row,value)
    }
    /// Satırları tek yüzeyde toplar.
    func group(_ rows:[NSView])->NSView {
        let surface=Surface()
        let stack=NSStackView(views:rows);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=8
        stack.translatesAutoresizingMaskIntoConstraints=false;surface.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:12),stack.trailingAnchor.constraint(equalTo:surface.trailingAnchor,constant:-12),stack.topAnchor.constraint(equalTo:surface.topAnchor,constant:10),stack.bottomAnchor.constraint(equalTo:surface.bottomAnchor,constant:-10),surface.widthAnchor.constraint(equalToConstant:Self.width)])
        return surface
    }
    func addFooter(leading:[NSView]) {
        footer.font = .systemFont(ofSize:10);footer.textColor=Vital.alert;footer.isHidden=true
        footer.widthAnchor.constraint(equalToConstant:Self.width).isActive=true
        content.addArrangedSubview(footer)
        let history=PillButton(title:L("Geçmiş","History"),tip:L("Geçmiş penceresini aç","Open History window"),target:self,action:#selector(openHistory))
        let pause=PillButton(symbol:"pause.fill",tip:L("İzlemeyi duraklat","Pause monitoring"),target:self,action:#selector(togglePause))
        let settings=PillButton(symbol:"slider.horizontal.3",tip:L("Ayarlar","Settings"),target:self,action:#selector(openSettings))
        let quit=PillButton(symbol:"power",tip:L("Nabız'dan çık","Quit Nabız"),target:self,action:#selector(quitApp))
        pauseButton=pause
        let bar=NSStackView(views:leading+[NSView(),history,pause,settings,quit]);bar.orientation = .horizontal;bar.spacing=6
        bar.widthAnchor.constraint(equalToConstant:Self.width).isActive=true
        content.addArrangedSubview(bar);content.setCustomSpacing(12,after:footer)
        setPaused(paused)
    }
    func setPaused(_ paused:Bool) {
        self.paused=paused
        pauseButton?.setSymbol(paused ? "play.fill":"pause.fill",tip:paused ? L("İzlemeyi sürdür","Resume monitoring"):L("İzlemeyi duraklat","Pause monitoring"))
        setLive(lastDate)
    }
    func setLive(_ date:Date?) {
        lastDate=date
        let when=date.map{L("Son ölçüm","Last sample")+" \(clock.string(from:$0)). "} ?? ""
        if paused {badge.set(L("DURAKLADI","PAUSED"),color:Vital.heat,pulse:false,tip:L("Değerler duraklatıldığı andaki hâliyle duruyor.","Values are frozen at the moment you paused."))}
        else if date==nil {badge.set(L("BAĞLANIYOR","STARTING"),color:Vital.faint,pulse:true,tip:L("İlk ölçüm bekleniyor.","Waiting for the first sample."))}
        else {badge.set(L("CANLI","LIVE"),color:Vital.cpu,pulse:true,tip:when+L("Her \(Prefs.interval) saniyede yenilenir; ölçümler bu Mac'ten çıkmaz.","Refreshes every \(Prefs.interval) s; measurements never leave this Mac."))}
    }
    func showStatus(_ sample:Snapshot) {
        setLive(sample.date)
        footer.stringValue=sample.storageError ?? "";footer.isHidden=sample.storageError==nil
    }
    func fitSize() {
        view.layoutSubtreeIfNeeded()
        let size=NSSize(width:Self.width+32,height:ceil(view.fittingSize.height))
        if abs(size.height-preferredContentSize.height)>0.5 || preferredContentSize.width != size.width {preferredContentSize=size}
    }
    @objc private func openHistory(){actions.history()}
    @objc private func openSettings(){actions.settings()}
    @objc private func togglePause(){actions.pause()}
    @objc private func quitApp(){actions.quit()}
}

/// Sistem öğesinin paneli: büyük işlemci izi, üç yaşam belirtisi, ayrıntılar ve canlı uygulama yükü.
final class SystemPanel: BasePanel {
    private let cpuValue=glowLabel("—",size:40,weight:.bold,color:Vital.cpu)
    private let cpuSplit=NSTextField(labelWithString:"")
    private let cpuTrace=TraceView()
    private let memory=VitalTile(L("BELLEK","MEMORY"),color:Vital.memory,width:(BasePanel.width-16)/3)
    private let gpu=VitalTile("GPU",color:Vital.gpu,width:(BasePanel.width-16)/3)
    private let heat=VitalTile(L("ISI","THERMAL"),color:Vital.heat,width:(BasePanel.width-16)/3)
    private var rows:[String:(NSView,NSTextField)]=[:]
    private let appsBox=NSStackView()
    private var appsGroup:NSView?
    override func loadView() {
        makeView(title:"Nabız",subtitle:L("Sistem","System"))
        let hero=Surface(radius:14)
        cpuTrace.color=Vital.cpu;cpuTrace.grid=true;cpuTrace.lineWidth=2;cpuTrace.translatesAutoresizingMaskIntoConstraints=false
        cpuSplit.font = .monospacedDigitSystemFont(ofSize:10,weight:.medium);cpuSplit.textColor=Vital.dim
        let label=caps(L("İŞLEMCİ","CPU"),color:Vital.cpu.withAlphaComponent(0.9))
        for v in [cpuTrace,label,cpuValue,cpuSplit] as [NSView] {v.translatesAutoresizingMaskIntoConstraints=false;hero.addSubview(v)}
        NSLayoutConstraint.activate([hero.widthAnchor.constraint(equalToConstant:Self.width),hero.heightAnchor.constraint(equalToConstant:126),
            label.leadingAnchor.constraint(equalTo:hero.leadingAnchor,constant:12),label.topAnchor.constraint(equalTo:hero.topAnchor,constant:11),
            cpuValue.leadingAnchor.constraint(equalTo:hero.leadingAnchor,constant:11),cpuValue.topAnchor.constraint(equalTo:label.bottomAnchor,constant:-1),
            cpuSplit.trailingAnchor.constraint(equalTo:hero.trailingAnchor,constant:-12),cpuSplit.centerYAnchor.constraint(equalTo:label.centerYAnchor),
            cpuTrace.leadingAnchor.constraint(equalTo:hero.leadingAnchor,constant:1),cpuTrace.trailingAnchor.constraint(equalTo:hero.trailingAnchor,constant:-1),
            cpuTrace.bottomAnchor.constraint(equalTo:hero.bottomAnchor,constant:-6),cpuTrace.heightAnchor.constraint(equalToConstant:60)])
        content.addArrangedSubview(hero)
        let tiles=NSStackView(views:[memory,gpu,heat]);tiles.orientation = .horizontal;tiles.spacing=8;tiles.alignment = .top
        content.addArrangedSubview(tiles)
        let specs:[(String,String,String?,NSColor)]=[
            ("pressure",L("Bellek baskısı","Memory pressure"),L("macOS bellek baskısı göstergesi; RAM yüzdesinden tahmin edilmez.","macOS memory pressure indicator; not guessed from RAM percentage."),Vital.memory),
            ("swap",L("Swap · sıkıştırılmış","Swap · compressed"),L("Diske taşınan / bellekte sıkıştırılan veri.","Data moved to disk / compressed in memory."),Vital.memory),
            ("fans",L("Fanlar","Fans"),L("Gerçek dönüş hızı; Nabız fan ayarını değiştirmez. 0 RPM fanın durduğunu gösterir.","Actual fan speed; Nabız never changes fan settings. 0 RPM means the fan is stopped."),Vital.heat),
            ("thermal",L("macOS ısı durumu","macOS thermal state"),L("macOS'un genel ısı değerlendirmesi; sensör sıcaklığıyla aynı ölçüm değildir.","macOS's overall thermal assessment; not the same as a sensor temperature."),Vital.heat),
            ("disk",L("Boş disk","Free disk"),L("Ana klasörün bulunduğu birim; dakikada bir yenilenir.","The volume holding your home folder; refreshed every minute."),Vital.gpu),
        ]
        var views:[NSView]=[]
        for (key,label,tip,color) in specs {let r=row(label,tip:tip,dot:color);rows[key]=r;views.append(r.0)}
        content.addArrangedSubview(group(views))
        appsBox.orientation = .vertical;appsBox.alignment = .leading;appsBox.spacing=7
        let appsTitle=caps(L("ŞU AN EN ÇOK İŞLEMCİ KULLANAN","TOP CPU RIGHT NOW"));appsTitle.toolTip=L("Son birkaç saniye, tek çekirdek ölçeğinde (100%'ü aşabilir). Kaydedilmez.","Last few seconds, per-core scale (can exceed 100%). Not saved.")
        let appsStack=NSStackView(views:[appsTitle,appsBox]);appsStack.orientation = .vertical;appsStack.alignment = .leading;appsStack.spacing=8
        let surface=Surface();appsStack.translatesAutoresizingMaskIntoConstraints=false;surface.addSubview(appsStack)
        NSLayoutConstraint.activate([appsStack.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:12),appsStack.trailingAnchor.constraint(equalTo:surface.trailingAnchor,constant:-12),appsStack.topAnchor.constraint(equalTo:surface.topAnchor,constant:10),appsStack.bottomAnchor.constraint(equalTo:surface.bottomAnchor,constant:-10),surface.widthAnchor.constraint(equalToConstant:Self.width)])
        appsGroup=surface;content.addArrangedSubview(surface)
        let monitor=PillButton(title:L("Etkinlik Monitörü","Activity Monitor"),tip:L("macOS Etkinlik Monitörü'nü aç","Open macOS Activity Monitor"),target:self,action:#selector(openMonitor))
        addFooter(leading:[monitor])
    }
    func update(_ sample:Snapshot,traces:Traces) {
        _ = view
        let hot=Prefs.highlight && (sample.cpu ?? 0)>=Double(Prefs.cpuThreshold)
        cpuValue.stringValue=percent(sample.cpu);setGlow(cpuValue,hot ? Vital.alert:Vital.cpu)
        cpuTrace.color=hot ? Vital.alert:Vital.cpu;cpuTrace.values=traces.cpu.values
        cpuSplit.stringValue=sample.cpuUser.flatMap{u in sample.cpuSystem.map{String(format:L("uygulamalar %.0f%%  ·  sistem %.0f%%","apps %.0f%%  ·  system %.0f%%"),u,$0)}} ?? ""
        let mem=sample.ramTotal>0 ? sample.ramUsed/sample.ramTotal*100:0
        memory.set(sample.memoryValid ? percent(mem):"—",sample.memoryValid ? "\(gib(sample.ramUsed)) / \(gib(sample.ramTotal)) GiB":L("okunamadı","unavailable"),trace:traces.memory.values,color:sample.pressure>=2 ? Vital.heat:nil)
        gpu.set(percent(sample.gpu),sample.gpu==nil ? L("okunamıyor","unavailable"):L("grafik yükü","graphics load"),trace:traces.gpu.values)
        if sample.sensors {
            heat.set(sample.temperature.map{String(format:"%.0f°",$0)} ?? "—",L("en sıcak çekirdek","hottest core"),trace:traces.heat.values,ceiling:105,color:(sample.temperature ?? 0)>=90 ? Vital.alert:nil)
        } else {
            let level=thermalLevel()
            heat.set([L("Normal","Normal"),L("Ilık","Warm"),L("Yüksek","High"),L("Kritik","Critical")][min(3,level)],L("macOS'a göre","per macOS"),trace:traces.heat.values,ceiling:100,color:level>=2 ? Vital.alert:nil)
        }
        rows["fans"]?.0.isHidden=sample.fans.isEmpty
        rows["fans"]?.1.stringValue=sample.fans.map{$0.0.map{String(format:"%.0f",$0)} ?? "—"}.joined(separator:" / ")+" RPM"
        rows["pressure"]?.1.stringValue=pressureText(sample.pressure)
        rows["pressure"]?.1.textColor=sample.pressure==4 ? Vital.alert:sample.pressure==2 ? Vital.heat:Vital.text
        rows["swap"]?.1.stringValue="\(gib(sample.swap)) · \(gib(sample.compressed)) GiB"
        rows["disk"]?.1.stringValue=sample.diskFree.map{"\(gib($0)) GiB"} ?? "—"
        rows["thermal"]?.0.isHidden = !sample.sensors
        rows["thermal"]?.1.stringValue=thermalText()
        appsGroup?.isHidden = !Prefs.liveApps
        if Prefs.liveApps {showApps(sample.liveApps)}
        showStatus(sample);fitSize()
    }
    private func showApps(_ apps:[AppLoad]?) {
        appsBox.arrangedSubviews.forEach{appsBox.removeArrangedSubview($0);$0.removeFromSuperview()}
        guard let apps,!apps.isEmpty else {
            let empty=NSTextField(labelWithString:apps==nil ? L("Ölçülüyor…","Measuring…"):L("Belirgin yük yok · her şey sakin","No notable load · all calm"));empty.font = .systemFont(ofSize:11.5);empty.textColor=Vital.faint
            appsBox.addArrangedSubview(empty);return
        }
        let top=max(100,apps.map{$0.cpu}.max() ?? 100)
        for app in apps {
            let name=NSTextField(labelWithString:app.name);name.font = .systemFont(ofSize:11.5,weight:.medium);name.textColor=Vital.text;name.lineBreakMode = .byTruncatingTail;name.toolTip=app.name
            let value=NSTextField(labelWithString:String(format:"%.0f%%",app.cpu));value.font = .monospacedDigitSystemFont(ofSize:11.5,weight:.semibold);value.textColor=Vital.cpu;value.alignment = .right
            let bar=ShareBar();bar.fraction=app.cpu/top;bar.tint=Vital.cpu;bar.track=Vital.line
            let line=NSStackView(views:[name,bar,value]);line.orientation = .horizontal;line.spacing=8;line.alignment = .centerY
            NSLayoutConstraint.activate([name.widthAnchor.constraint(equalToConstant:150),value.widthAnchor.constraint(equalToConstant:44),bar.heightAnchor.constraint(equalToConstant:4),line.widthAnchor.constraint(equalToConstant:Self.width-24)])
            appsBox.addArrangedSubview(line)
        }
    }
    @objc private func openMonitor() {
        if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.ActivityMonitor") {NSWorkspace.shared.open(url)}
    }
}

/// Ağ öğesinin paneli: indirme üstte, gönderme altta aynalı canlı iz; günlük ve haftalık toplamlar.
final class NetworkPanel: BasePanel {
    private let downValue=glowLabel("—",size:26,weight:.bold,color:Vital.down)
    private let upValue=glowLabel("—",size:26,weight:.bold,color:Vital.up)
    private let trace=TraceView()
    private var stats:[String:(NSTextField,NSTextField)]=[:]
    override func loadView() {
        makeView(title:"Nabız",subtitle:L("Ağ","Network"))
        let hero=Surface(radius:14)
        trace.color=Vital.down;trace.mirrorColor=Vital.up;trace.ceiling=nil;trace.floorValue=8_000;trace.grid=true;trace.lineWidth=1.8;trace.mirror=[]
        let downLabel=caps(L("↓ İNDİRME","↓ DOWNLOAD"),color:Vital.down.withAlphaComponent(0.9)),upLabel=caps(L("↑ GÖNDERME","↑ UPLOAD"),color:Vital.up.withAlphaComponent(0.9))
        let left=NSStackView(views:[downLabel,downValue]);left.orientation = .vertical;left.alignment = .leading;left.spacing=0
        let right=NSStackView(views:[upLabel,upValue]);right.orientation = .vertical;right.alignment = .trailing;right.spacing=0
        for v in [left,right,trace] as [NSView] {v.translatesAutoresizingMaskIntoConstraints=false;hero.addSubview(v)}
        NSLayoutConstraint.activate([hero.widthAnchor.constraint(equalToConstant:Self.width),hero.heightAnchor.constraint(equalToConstant:180),
            left.leadingAnchor.constraint(equalTo:hero.leadingAnchor,constant:12),left.topAnchor.constraint(equalTo:hero.topAnchor,constant:11),
            right.trailingAnchor.constraint(equalTo:hero.trailingAnchor,constant:-12),right.topAnchor.constraint(equalTo:hero.topAnchor,constant:11),
            trace.leadingAnchor.constraint(equalTo:hero.leadingAnchor,constant:1),trace.trailingAnchor.constraint(equalTo:hero.trailingAnchor,constant:-1),
            trace.topAnchor.constraint(equalTo:left.bottomAnchor,constant:8),trace.bottomAnchor.constraint(equalTo:hero.bottomAnchor,constant:-6)])
        content.addArrangedSubview(hero)
        let specs:[(String,String,String)]=[
            ("average",L("ORTALAMA","AVERAGE"),L("Grafiğin kapsadığı son dakikaların ortalaması.","Average over the minutes shown in the graph.")),
            ("peak",L("EN YÜKSEK","PEAK"),L("Nabız açıldığından beri ölçülen en yüksek hız.","Highest speed measured since Nabız opened.")),
            ("today",L("BUGÜN","TODAY"),L("Bugün Nabız açıkken geçen trafik. Önceki saatler geri getirilemez.","Traffic today while Nabız was open. Earlier hours can't be recovered.")),
            ("week",L("SON 7 GÜN","LAST 7 DAYS"),L("Bugün dahil son 7 gün; yalnız Nabız'ın açık olduğu süreler.","Last 7 days including today; only while Nabız was open.")),
        ]
        let tileWidth=(Self.width-8)/2
        var tiles:[NSView]=[]
        for (key,title,tip) in specs {
            let surface=Surface();surface.toolTip=tip
            let label=caps(title)
            let d=NSTextField(labelWithString:"—"),u=NSTextField(labelWithString:"—")
            d.font = .monospacedDigitSystemFont(ofSize:13,weight:.semibold);d.textColor=Vital.down
            u.font = .monospacedDigitSystemFont(ofSize:13,weight:.semibold);u.textColor=Vital.up
            let stack=NSStackView(views:[label,d,u]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=3;stack.setCustomSpacing(6,after:label)
            stack.translatesAutoresizingMaskIntoConstraints=false;surface.addSubview(stack)
            NSLayoutConstraint.activate([surface.widthAnchor.constraint(equalToConstant:tileWidth),stack.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:11),stack.topAnchor.constraint(equalTo:surface.topAnchor,constant:9),stack.bottomAnchor.constraint(equalTo:surface.bottomAnchor,constant:-9)])
            stats[key]=(d,u);tiles.append(surface)
        }
        for pair in [Array(tiles[0..<2]),Array(tiles[2..<4])] {let line=NSStackView(views:pair);line.orientation = .horizontal;line.spacing=8;content.addArrangedSubview(line)}
        let note=NSTextField(wrappingLabelWithString:L("Wi‑Fi ve Ethernet toplamı, yalnız Nabız açıkken.","Wi‑Fi and Ethernet combined, only while Nabız is open."))
        note.font = .systemFont(ofSize:9.5);note.textColor=Vital.faint
        note.widthAnchor.constraint(equalToConstant:Self.width).isActive=true
        content.addArrangedSubview(note)
        addFooter(leading:[])
    }
    func update(_ sample:Snapshot,traces:Traces) {
        _ = view
        downValue.stringValue=spaced(sample.download);upValue.stringValue=spaced(sample.upload)
        trace.values=traces.down.values;trace.mirror=traces.up.values
        func put(_ key:String,_ d:String,_ u:String){stats[key]?.0.stringValue="↓ "+d;stats[key]?.1.stringValue="↑ "+u}
        put("average",spaced(traces.down.average),spaced(traces.up.average))
        put("peak",spaced(traces.peakDown),spaced(traces.peakUp))
        put("today",compactBytes(sample.today.received),compactBytes(sample.today.sent))
        put("week",compactBytes(sample.week.received),compactBytes(sample.week.sent))
        showStatus(sample);fitSize()
    }
    private func spaced(_ value:Double?)->String {
        let text=rate(value)
        guard let index=text.firstIndex(where:{$0.isLetter}) else {return text}
        return text[..<index]+" "+text[index...]
    }
}

/// Nabız işareti: nabız çizgisi "N" harfini çizer. Uygulama simgesiyle aynı geometri (Icon.swift).
enum NabizMark {
    static let points:[CGPoint]=[.init(x:150,y:560),.init(x:300,y:560),.init(x:370,y:300),.init(x:600,y:720),.init(x:670,y:300),.init(x:740,y:560),.init(x:874,y:560)]
    static func image(size:CGFloat)->NSImage {
        NSImage(size:NSSize(width:size,height:size),flipped:true) { rect in
            guard let c=NSGraphicsContext.current?.cgContext else {return false}
            let s=rect.width/1024;c.scaleBy(x:s,y:s)
            let path=CGMutablePath();path.addLines(between:points)
            let stroke=path.copy(strokingWithWidth:100,lineCap:.round,lineJoin:.round,miterLimit:10)
            c.addPath(stroke);c.clip()
            let space=CGColorSpace(name:CGColorSpace.sRGB)!
            let g=CGGradient(colorsSpace:space,colors:[Vital.cpu.cgColor,Vital.memory.cgColor] as CFArray,locations:[0,1])!
            c.drawLinearGradient(g,start:CGPoint(x:150,y:0),end:CGPoint(x:874,y:0),options:[])
            return true
        }
    }
}
