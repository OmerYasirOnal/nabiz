import AppKit

// Geçmiş penceresi (1.6): panellerle aynı monitör dili, üç soru:
// fanlar (App Store sürümünde ısı baskısı) ne zaman yükseldi, ne kadar ağ kullanıldı, o sırada ne çalışıyordu.
// Pencere yalnız açıkken var olur.

/// Geçmişin "zorlanma" ölçütü. Doğrudan dağıtım sürümü fan RPM'i, Mac App Store sürümü (SMC yok) macOS ısı baskısını kullanır.
enum HistoryTerms {
    #if NABIZ_APPSTORE
    static var tile:String {L("ISI BASKISI","THERMAL PRESSURE")}
    static var question:String {L("ISI BASKISI NE ZAMAN ARTTI?","WHEN DID THERMAL PRESSURE RISE?")}
    static var legend:String {L("ısı baskısı","thermal pressure")}
    static var tileTip:String {L("macOS ısı baskısının \"hafif artmış\" veya üstünde olduğu süre.","Time macOS thermal pressure was \"fair\" or higher.")}
    static var calm:String {L("Bu aralıkta ısı baskısı hiç artmadı.","Thermal pressure never rose in this range.")}
    static var apps:String {L("ISI BASKISI ARTARKEN ÇALIŞAN UYGULAMALAR","APPS RUNNING WHILE THERMAL PRESSURE ROSE")}
    static var noApps:String {L("Isı baskısıyla aynı anda belirgin işlemci yükü ölçülmedi.","No notable CPU load was measured during thermal pressure.")}
    static var record:String {L("Isı geçmişini kaydet","Record thermal history")}
    static var empty:String {L("Kayıt kapalı. Açarsanız Nabız dakikada bir kısa özet tutar: ısı baskısının ne zaman arttığını ve o sırada hangi uygulamaların çalıştığını burada görürsünüz.","Recording is off. Turn it on and Nabız keeps a short summary every minute: see here when thermal pressure rose and which apps were running.")}
    #else
    static var tile:String {L("YÜKSEK FAN","HIGH FAN")}
    static var question:String {L("FANLAR NE ZAMAN YÜKSEK DÖNDÜ?","WHEN DID THE FANS RUN HIGH?")}
    static var legend:String {L("yüksek fan","high fan")}
    static var tileTip:String {L("En az bir fanın 3500 RPM ve üstünde döndüğü süre.","Time at least one fan ran at 3500 RPM or more.")}
    static var calm:String {L("Bu aralıkta fanlar hiç yüksek dönmedi.","The fans never ran high in this range.")}
    static var apps:String {L("FANLAR YÜKSEKKEN ÇALIŞAN UYGULAMALAR","APPS RUNNING WHILE FANS WERE HIGH")}
    static var noApps:String {L("Yüksek fanla aynı anda belirgin işlemci yükü ölçülmedi.","No notable CPU load was measured while the fans were high.")}
    static var record:String {L("Isı ve fan geçmişini kaydet","Record thermal and fan history")}
    static var empty:String {L("Kayıt kapalı. Açarsanız Nabız dakikada bir kısa özet tutar: fanların ne zaman yükseldiğini, en yüksek sıcaklığı ve o sırada hangi uygulamaların çalıştığını burada görürsünüz.","Recording is off. Turn it on and Nabız keeps a short summary every minute: see here when the fans ran high, the peak temperature and which apps were running.")}
    #endif
}

/// Açık/koyu görünüme kendiliğinden uyan, kenarlıklı yüzey (Ayarlar penceresi kullanır).
class CardView: NSView {
    override var wantsUpdateLayer:Bool {true}
    init(){super.init(frame:.zero);wantsLayer=true;translatesAutoresizingMaskIntoConstraints=false}
    required init?(coder:NSCoder){fatalError()}
    override func updateLayer() {
        layer?.cornerRadius=10;layer?.borderWidth=1
        layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor
        layer?.borderColor=NSColor.separatorColor.cgColor
    }
}

func historyDuration(_ seconds:Double)->String {
    let s=max(0,seconds.isFinite ? seconds:0)
    if s<60 {return String(format:L("%.0f sn","%.0f s"),s)}
    let minutes=Int(s/60)
    if minutes<60 {return "\(minutes) "+L("dk","min")}
    let hours=minutes/60,rest=minutes%60
    return hours>=10 || rest==0 ? "\(hours) "+L("sa","h"):"\(hours) "+L("sa","h")+" \(rest) "+L("dk","min")
}

/// İnce orantı çubuğu.
final class ShareBar: NSView {
    var fraction:Double=0 {didSet{needsDisplay=true}}
    var tint:NSColor=Vital.heat {didSet{needsDisplay=true}}
    var track:NSColor=Vital.line
    override var intrinsicContentSize:NSSize {NSSize(width:NSView.noIntrinsicMetric,height:6)}
    override func draw(_ dirtyRect:NSRect) {
        let r=bounds.height/2
        track.setFill();NSBezierPath(roundedRect:bounds,xRadius:r,yRadius:r).fill()
        let width=max(bounds.height,bounds.width*min(1,max(0,fraction)))
        tint.setFill();NSBezierPath(roundedRect:NSRect(x:0,y:0,width:width,height:bounds.height),xRadius:r,yRadius:r).fill()
    }
}

/// Saat/gün başına çubuk grafik. Turuncu: zorlanma dakikası. Yeşil taban: ölçüldü ve sakindi. Boş: Nabız kapalıydı.
/// `traffic` modunda günlük indirme/gönderme yan yana çizilir.
final class BarChart: NSView {
    enum Mode { case strain, traffic }
    var mode:Mode = .strain
    var buckets:[HistoryBucket]=[] {didSet{needsDisplay=true;updateAccessibility()}}
    var hourly=true {didSet{needsDisplay=true}}
    private let axisHeight:CGFloat=16
    override var isFlipped:Bool {false}
    override var intrinsicContentSize:NSSize {NSSize(width:NSView.noIntrinsicMetric,height:mode == .strain ? 104:84)}
    override init(frame:NSRect){super.init(frame:frame);addToolTip(bounds,owner:self,userData:nil)}
    required init?(coder:NSCoder){fatalError()}
    override func setFrameSize(_ size:NSSize){super.setFrameSize(size);removeAllToolTips();addToolTip(bounds,owner:self,userData:nil)}
    private func slots()->[NSRect] {
        guard !buckets.isEmpty else {return []}
        let gap:CGFloat=buckets.count>14 ? 4:7
        let width=(bounds.width-gap*CGFloat(buckets.count-1))/CGFloat(buckets.count)
        return buckets.indices.map{NSRect(x:CGFloat($0)*(width+gap),y:axisHeight,width:width,height:bounds.height-axisHeight)}
    }
    private var scale:Double {
        switch mode {
        case .strain: return max(hourly ? 600:3600,buckets.map{$0.high}.max() ?? 0)
        case .traffic: return max(1_000_000,Double(buckets.map{max($0.traffic?.received ?? 0,$0.traffic?.sent ?? 0)}.max() ?? 0))
        }
    }
    override func draw(_ dirtyRect:NSRect) {
        let rects=slots(),top=scale
        for (bucket,rect) in zip(buckets,rects) {
            let r=min(3,rect.width/2)
            NSColor(white:1,alpha:0.04).setFill();NSBezierPath(roundedRect:rect,xRadius:r,yRadius:r).fill()
            switch mode {
            case .strain:
                if bucket.high>0 {
                    let h=max(4,rect.height*CGFloat(min(1,bucket.high/top)))
                    let bar=NSRect(x:rect.minX,y:rect.minY,width:rect.width,height:h)
                    NSGraphicsContext.saveGraphicsState()
                    let glow=NSShadow();glow.shadowColor=Vital.heat.withAlphaComponent(0.6);glow.shadowBlurRadius=6;glow.set()
                    NSGradient(colors:[Vital.heat,Vital.alert])!.draw(in:NSBezierPath(roundedRect:bar,xRadius:r,yRadius:r),angle:90)
                    NSGraphicsContext.restoreGraphicsState()
                } else if bucket.seconds>0 {
                    Vital.cpu.withAlphaComponent(0.7).setFill()
                    NSBezierPath(roundedRect:NSRect(x:rect.minX,y:rect.minY,width:rect.width,height:3),xRadius:1.5,yRadius:1.5).fill()
                }
            case .traffic:
                let t=bucket.traffic ?? Traffic()
                let half=(rect.width-2)/2
                for (i,(value,color)) in [(t.received,Vital.down),(t.sent,Vital.up)].enumerated() where value>0 {
                    let h=max(3,rect.height*CGFloat(min(1,Double(value)/top)))
                    color.setFill();NSBezierPath(roundedRect:NSRect(x:rect.minX+CGFloat(i)*(half+2),y:rect.minY,width:half,height:h),xRadius:min(2,half/2),yRadius:min(2,half/2)).fill()
                }
            }
        }
        let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:9,weight:.medium),.foregroundColor:Vital.faint]
        for (index,text) in axisLabels() {
            let label=NSAttributedString(string:text,attributes:attributes),size=label.size()
            var x:CGFloat
            if hourly {x=bounds.width*CGFloat(index)/24-size.width/2}
            else {guard rects.indices.contains(index) else {continue};x=rects[index].midX-size.width/2}
            label.draw(at:NSPoint(x:min(bounds.width-size.width,max(0,x)),y:1))
        }
    }
    private func axisLabels()->[(Int,String)] {
        if hourly {return [0,6,12,18,24].map{($0,String(format:"%02d:00",$0 % 24 == 0 && $0 > 0 ? 24:$0))}}
        let f=DateFormatter();f.locale=appLocale;f.dateFormat=buckets.count>7 ? "d MMM":"EEE"
        let picks=buckets.count>7 ? [0,buckets.count/2,buckets.count-1]:Array(buckets.indices)
        return picks.map{($0,$0==buckets.count-1 ? L("Bugün","Today"):f.string(from:buckets[$0].start))}
    }
    private func label(for bucket:HistoryBucket)->String {
        let f=DateFormatter();f.locale=appLocale
        var head:String
        if hourly {f.dateFormat="HH:mm";head="\(f.string(from:bucket.start))–\(f.string(from:bucket.start.addingTimeInterval(3600)))"}
        else {f.dateFormat=appIsTurkish ? "d MMMM EEEE":"EEEE, MMMM d";head=f.string(from:bucket.start)}
        if mode == .traffic {
            let t=bucket.traffic ?? Traffic()
            return t.received+t.sent==0 ? "\(head)\n"+L("Ölçüm yok","No data"):"\(head)\n↓ \(compactBytes(t.received))   ↑ \(compactBytes(t.sent))"
        }
        guard bucket.seconds>0 else {return "\(head)\n"+L("Nabız kapalıydı ya da kayıt yoktu","Nabız was closed or not recording")}
        var lines=[head,bucket.high>0 ? "\(HistoryTerms.legend.capitalized(with:appLocale)): \(historyDuration(bucket.high))":L("Sakin","Calm")]
        if let t=bucket.maxTemp {lines.append(String(format:L("En sıcak çekirdek: %.0f°C","Hottest core: %.0f°C"),t))}
        return lines.joined(separator:"\n")
    }
    @objc func view(_ view:NSView,stringForToolTip tag:NSView.ToolTipTag,point:NSPoint,userData data:UnsafeMutableRawPointer?)->String {
        guard let index=slots().firstIndex(where:{$0.insetBy(dx:-2,dy:0).minX<=point.x && point.x<=$0.insetBy(dx:-2,dy:0).maxX}) else {return ""}
        return label(for:buckets[index])
    }
    private func updateAccessibility() {
        setAccessibilityElement(true);setAccessibilityRole(.image)
        setAccessibilityLabel(mode == .traffic ? L("Günlük ağ kullanımı grafiği","Daily network usage chart"):(hourly ? L("Saat saat zorlanma grafiği","Hourly load chart"):L("Gün gün zorlanma grafiği","Daily load chart")))
        setAccessibilityValue(mode == .traffic ? "\(buckets.count) "+L("gün","days"):"\(buckets.filter{$0.high>0}.count) "+L("dilimde","slots with")+" \(HistoryTerms.legend)")
    }
}

/// Özet kutusu: başlık, büyük parlayan değer, alt açıklama.
final class SummaryTile: NSView {
    let value:NSTextField,detail=NSTextField(labelWithString:"")
    init(_ title:String,color:NSColor) {
        value=glowLabel("—",size:24,weight:.bold,color:color)
        super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false
        let surface=Surface();addSubview(surface)
        detail.font = .systemFont(ofSize:10.5);detail.textColor=Vital.dim;detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let stack=NSStackView(views:[caps(title,color:color.withAlphaComponent(0.9)),value,detail]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=2
        stack.translatesAutoresizingMaskIntoConstraints=false;addSubview(stack)
        NSLayoutConstraint.activate([surface.leadingAnchor.constraint(equalTo:leadingAnchor),surface.trailingAnchor.constraint(equalTo:trailingAnchor),surface.topAnchor.constraint(equalTo:topAnchor),surface.bottomAnchor.constraint(equalTo:bottomAnchor),
            stack.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12),stack.trailingAnchor.constraint(lessThanOrEqualTo:trailingAnchor,constant:-10),stack.topAnchor.constraint(equalTo:topAnchor,constant:10),stack.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-10)])
        setAccessibilityElement(true);setAccessibilityRole(.group);setAccessibilityLabel(title)
    }
    required init?(coder:NSCoder){fatalError()}
    func set(_ text:String,_ sub:String,color:NSColor?=nil){value.stringValue=text;if let color {setGlow(value,color)};detail.stringValue=sub;setAccessibilityValue("\(text), \(sub)")}
}

final class HistoryController:NSWindowController,NSWindowDelegate {
    static let contentWidth:CGFloat=480
    let enabled=NSSwitch()
    let range=NSSegmentedControl(labels:[L("Bugün","Today"),L("7 gün","7 days"),L("14 gün","14 days")],trackingMode:.selectOne,target:nil,action:nil)
    private let strain=SummaryTile(HistoryTerms.tile,color:Vital.heat)
    private let hottest=SummaryTile(L("EN SICAK","HOTTEST"),color:Vital.heat)
    private let network=SummaryTile(L("AĞ","NETWORK"),color:Vital.down)
    private let chart=BarChart()
    private let answer=NSTextField(wrappingLabelWithString:"")
    private let legend=NSTextField(labelWithString:"")
    private var chartGroup:NSView!
    private var emptyGroup:NSView!
    private let netChart=BarChart()
    private var netGroup:NSView!
    private let appsList=NSStackView()
    private var appsGroup:NSView!
    private let status=NSTextField(wrappingLabelWithString:"")
    private let root=NSStackView()
    var onClose:(()->Void)?
    var onToggle:((Bool)->Void)?
    var onRefresh:((Int)->Void)?
    var selectedDays:Int {[1,7,14][max(0,min(2,range.selectedSegment))]}

    init() {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:Self.contentWidth+40,height:560),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title=L("Nabız · Geçmiş","Nabız · History");window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true;window.isReleasedWhenClosed=false
        window.appearance=NSAppearance(named:.darkAqua);window.isMovableByWindowBackground=true
        let background=MonitorBackground();window.contentView=background
        super.init(window:window);window.delegate=self
        let width=Self.contentWidth
        root.orientation = .vertical;root.alignment = .leading;root.spacing=12
        root.translatesAutoresizingMaskIntoConstraints=false;background.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:background.leadingAnchor,constant:20),root.topAnchor.constraint(equalTo:background.topAnchor,constant:40),root.widthAnchor.constraint(equalToConstant:width)])

        // Başlık
        let mark=NSImageView(image:NabizMark.image(size:28));mark.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant:28),mark.heightAnchor.constraint(equalToConstant:28)])
        let title=NSTextField(labelWithString:L("Geçmiş","History"));title.font = .systemFont(ofSize:20,weight:.bold);title.textColor=Vital.text
        range.selectedSegment=max(0,min(2,UserDefaults.standard.integer(forKey:"historyRange")))
        range.target=self;range.action=#selector(rangeChanged);range.setAccessibilityLabel(L("Geçmiş aralığı","History range"))
        let head=NSStackView(views:[mark,title,NSView(),range]);head.orientation = .horizontal;head.spacing=10;head.alignment = .centerY
        root.addArrangedSubview(head);root.setCustomSpacing(16,after:head)

        // Özet
        strain.toolTip=HistoryTerms.tileTip
        hottest.toolTip=L("Seçili aralıkta ölçülen en sıcak işlemci çekirdeği; kasa sıcaklığı değildir.","Hottest CPU core measured in the selected range; not the case temperature.")
        network.toolTip=L("Nabız açıkken geçen trafik; kayıt kapalıyken de tutulur.","Traffic while Nabız was open; kept even when recording is off.")
        var tileViews:[NSView]=[strain,hottest,network]
        #if NABIZ_APPSTORE
        tileViews=[strain,network] // App Store sürümü sıcaklık sensörü okumaz.
        #endif
        let tiles=NSStackView(views:tileViews);tiles.orientation = .horizontal;tiles.distribution = .fillEqually;tiles.spacing=8
        root.addArrangedSubview(tiles)

        // Zorlanma grafiği
        answer.font = .systemFont(ofSize:13,weight:.semibold);answer.textColor=Vital.text
        legend.attributedStringValue=Self.legendText()
        chart.mode = .strain
        chartGroup=Self.section(HistoryTerms.question,[answer,chart,legend],width:width)
        root.addArrangedSubview(chartGroup)

        // Kayıt kapalıyken sade açıklama
        let emptyText=NSTextField(wrappingLabelWithString:HistoryTerms.empty)
        emptyText.font = .systemFont(ofSize:12);emptyText.textColor=Vital.dim
        let start=PillButton(title:L("Kaydı başlat","Start recording"),tip:L("Geçmiş kaydını aç","Turn on history recording"),target:self,action:#selector(enableFromEmpty))
        emptyGroup=Self.section(HistoryTerms.question,[emptyText,start],width:width)
        root.addArrangedSubview(emptyGroup)

        // Günlük ağ
        netChart.mode = .traffic
        let netLegend=NSTextField(labelWithString:"");netLegend.attributedStringValue=Self.dots([(L("indirme","download"),Vital.down),(L("gönderme","upload"),Vital.up)])
        netGroup=Self.section(L("GÜNLÜK AĞ KULLANIMI","DAILY NETWORK USAGE"),[netChart,netLegend],width:width)
        root.addArrangedSubview(netGroup)

        // Uygulamalar
        appsList.orientation = .vertical;appsList.alignment = .leading;appsList.spacing=8
        let note=NSTextField(wrappingLabelWithString:L("Aynı anda ölçülen işlemci yükü; kesin neden değildir.","CPU load measured at the same time; not proof of cause."));note.font = .systemFont(ofSize:10);note.textColor=Vital.faint
        appsGroup=Self.section(HistoryTerms.apps,[appsList,note],width:width)
        root.addArrangedSubview(appsGroup)

        // Kayıt anahtarı
        enabled.target=self;enabled.action=#selector(toggle);enabled.controlSize = .small;enabled.setAccessibilityLabel(HistoryTerms.record)
        let recordLabel=NSTextField(labelWithString:HistoryTerms.record);recordLabel.font = .systemFont(ofSize:12,weight:.medium);recordLabel.textColor=Vital.text
        let recordNote=NSTextField(labelWithString:L("Dakikada bir özet · 14 gün · yalnız bu Mac'te","One summary per minute · 14 days · this Mac only"));recordNote.font = .systemFont(ofSize:10);recordNote.textColor=Vital.faint
        let texts=NSStackView(views:[recordLabel,recordNote]);texts.orientation = .vertical;texts.alignment = .leading;texts.spacing=1
        let record=NSStackView(views:[texts,NSView(),enabled]);record.orientation = .horizontal;record.alignment = .centerY
        root.addArrangedSubview(record)
        status.font = .systemFont(ofSize:10);status.textColor=Vital.alert
        root.addArrangedSubview(status)
        for view in [head,tiles,chartGroup!,emptyGroup!,netGroup!,appsGroup!,record,status] {view.widthAnchor.constraint(equalToConstant:width).isActive=true}
        for view in [answer,chart,legend,emptyText,netChart,appsList,note] {view.widthAnchor.constraint(equalToConstant:width-28).isActive=true}
    }
    required init?(coder:NSCoder){fatalError()}

    private static func dots(_ items:[(String,NSColor)])->NSAttributedString {
        let s=NSMutableAttributedString()
        for (i,(text,color)) in items.enumerated() {
            if i>0 {s.append(NSAttributedString(string:"     "))}
            s.append(NSAttributedString(string:"● ",attributes:[.foregroundColor:color,.font:NSFont.systemFont(ofSize:9)]))
            s.append(NSAttributedString(string:text,attributes:[.foregroundColor:Vital.faint,.font:NSFont.systemFont(ofSize:10)]))
        }
        return s
    }
    private static func legendText()->NSAttributedString { dots([(HistoryTerms.legend,Vital.heat),(L("sakin","calm"),Vital.cpu),(L("boş: Nabız kapalıydı","empty: Nabız was closed"),NSColor(white:1,alpha:0.15))]) }
    private static func section(_ title:String,_ views:[NSView],width:CGFloat)->NSView {
        let surface=Surface(radius:14)
        let stack=NSStackView(views:[caps(title)]+views);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10
        stack.translatesAutoresizingMaskIntoConstraints=false;surface.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:surface.leadingAnchor,constant:14),stack.trailingAnchor.constraint(equalTo:surface.trailingAnchor,constant:-14),stack.topAnchor.constraint(equalTo:surface.topAnchor,constant:12),stack.bottomAnchor.constraint(equalTo:surface.bottomAnchor,constant:-12)])
        return surface
    }

    func display(_ data:HistorySummary,recording:Bool) {
        enabled.state=recording ? .on:.off
        let days=selectedDays,hasData=data.minutes>0
        let span=days==1 ? L("Bugün","Today"):L("Son \(days) gün","Last \(days) days")
        if hasData {
            let share=data.seconds>0 ? data.highSeconds/data.seconds*100:0
            strain.set(historyDuration(data.highSeconds),data.highSeconds>0 ? String(format:L("ölçülen sürenin %%%.0f'i","%.0f%% of measured time"),share):L("hiç olmadı","never"),color:data.highSeconds>0 ? Vital.heat:Vital.cpu)
            hottest.set(data.maxTemp.map{String(format:"%.0f°C",$0)} ?? "—",L("en sıcak çekirdek","hottest core"),color:(data.maxTemp ?? 0)>=90 ? Vital.alert:Vital.heat)
        } else {
            strain.set("—",recording ? L("veri toplanıyor","collecting data"):L("kayıt kapalı","recording off"),color:Vital.heat)
            hottest.set("—",recording ? L("veri toplanıyor","collecting data"):L("kayıt kapalı","recording off"))
        }
        let total=saturatedSum(data.traffic.received,data.traffic.sent)
        network.set(total>0 ? compactBytes(total):"—","↓ \(compactBytes(data.traffic.received))  ↑ \(compactBytes(data.traffic.sent))")

        chartGroup.isHidden = !hasData;emptyGroup.isHidden=hasData || recording
        if !hasData && recording {
            chartGroup.isHidden=false
            answer.stringValue=L("İlk özetler birkaç dakika içinde görünür.","The first summaries appear within a few minutes.")
        } else if data.highSeconds>0 {
            answer.stringValue="\(span) "+L("toplam","total")+" \(historyDuration(data.highSeconds))"+(data.busiest.map{" · "+L("en yoğun","busiest")+" \($0)"} ?? "")
        } else {
            answer.stringValue=HistoryTerms.calm
        }
        chart.hourly=data.hourly;chart.buckets=data.buckets
        chart.isHidden = !hasData;legend.isHidden = !hasData

        netGroup.isHidden=data.hourly || data.buckets.allSatisfy{($0.traffic?.received ?? 0)+($0.traffic?.sent ?? 0)==0}
        netChart.hourly=false;netChart.buckets=data.buckets

        appsList.arrangedSubviews.forEach{appsList.removeArrangedSubview($0);$0.removeFromSuperview()}
        appsGroup.isHidden = !hasData
        let apps=Array(data.applications.prefix(5))
        if apps.isEmpty {
            let empty=NSTextField(wrappingLabelWithString:HistoryTerms.noApps);empty.font = .systemFont(ofSize:11.5);empty.textColor=Vital.dim
            appsList.addArrangedSubview(empty);empty.widthAnchor.constraint(equalToConstant:Self.contentWidth-28).isActive=true
        } else {
            let top=max(1,apps.map{$0.cpu}.max() ?? 1)
            for app in apps {
                let name=NSTextField(labelWithString:app.name);name.font = .systemFont(ofSize:12,weight:.medium);name.textColor=Vital.text;name.lineBreakMode = .byTruncatingTail;name.toolTip=app.name
                let bar=ShareBar();bar.fraction=app.cpu/top;bar.tint=Vital.heat
                let cpu=NSTextField(labelWithString:String(format:"%.0f%%",app.cpu));cpu.font = .monospacedDigitSystemFont(ofSize:12,weight:.semibold);cpu.textColor=Vital.heat;cpu.alignment = .right
                cpu.toolTip=L("Ortalama işlemci kullanımı, tek çekirdek ölçeğinde (100%'ü aşabilir).","Average CPU use, per-core scale (can exceed 100%).")
                let row=NSStackView(views:[name,bar,cpu]);row.orientation = .horizontal;row.spacing=10;row.alignment = .centerY
                NSLayoutConstraint.activate([name.widthAnchor.constraint(equalToConstant:160),cpu.widthAnchor.constraint(equalToConstant:52),bar.heightAnchor.constraint(equalToConstant:5),row.widthAnchor.constraint(equalToConstant:Self.contentWidth-28)])
                row.setAccessibilityElement(true);row.setAccessibilityLabel("\(app.name), "+L("ortalama","average")+" \(cpu.stringValue) "+L("işlemci","CPU"))
                appsList.addArrangedSubview(row)
            }
        }
        status.stringValue=data.storageError ?? "";status.isHidden=data.storageError==nil
        resizeToFit()
    }
    private func resizeToFit() {
        guard let window=window else {return}
        root.layoutSubtreeIfNeeded()
        let height=root.fittingSize.height+60
        let size=NSSize(width:Self.contentWidth+40,height:height)
        guard abs(window.contentRect(forFrameRect:window.frame).height-height)>0.5 else {return}
        var frame=window.frameRect(forContentRect:NSRect(origin:.zero,size:size))
        frame.origin=NSPoint(x:window.frame.minX,y:window.frame.maxY-frame.height)
        window.setFrame(frame,display:true,animate:false)
    }
    func windowWillClose(_ notification:Notification){onClose?()}
    @objc private func toggle(){onToggle?(enabled.state == .on);refresh()}
    @objc private func enableFromEmpty(){enabled.state = .on;toggle()}
    @objc private func rangeChanged(){UserDefaults.standard.set(range.selectedSegment,forKey:"historyRange");refresh()}
    @objc func refresh(){onRefresh?(selectedDays)}
}
