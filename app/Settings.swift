import AppKit
import ServiceManagement

/// Arayüz dili: uygulamanın macOS tarafından seçilen yerelleştirmesi (tr veya en). NABIZ_LANG ile zorlanabilir (mağaza görselleri).
let appIsTurkish:Bool = {
    if let forced=ProcessInfo.processInfo.environment["NABIZ_LANG"] {return forced.hasPrefix("tr")}
    if let first=Bundle.main.preferredLocalizations.first,["tr","en"].contains(first),Bundle.main.localizations.contains("en") {return first=="tr"}
    return (Locale.preferredLanguages.first ?? "en").hasPrefix("tr")
}()
let appLocale=Locale(identifier:appIsTurkish ? "tr_TR":"en_US")
/// Türkçe ve İngilizce metin yan yana; uygulamanın diline göre biri döner.
func L(_ tr:String,_ en:String)->String {appIsTurkish ? tr:en}
func upper(_ text:String)->String {text.uppercased(with:appLocale)}

/// Tüm kullanıcı tercihleri tek yerde. Anahtarlar 1.5 ile uyumludur; yeni anahtarlar güvenli varsayılan alır.
enum Prefs {
    private static let store=UserDefaults.standard
    private static func int(_ key:String,_ fallback:Int,_ allowed:[Int])->Int {
        guard store.object(forKey:key) != nil else {return fallback}
        let value=store.integer(forKey:key);return allowed.contains(value) ? value:fallback
    }
    private static func bool(_ key:String,_ fallback:Bool)->Bool { store.object(forKey:key)==nil ? fallback:store.bool(forKey:key) }

    /// 0 CPU, 1 RAM, 2 kısa N.
    static var menuMode:Int { get{int("menuMode",0,[0,1,2])} set{store.set(newValue,forKey:"menuMode")} }
    /// 0 kapalı, 1 anlık hız, 2 bugünkü toplam.
    static var networkMode:Int { get{int("networkMode",1,[0,1,2])} set{store.set(newValue,forKey:"networkMode")} }
    /// 0 baskın yön, 1 yalnız indirme, 2 yalnız gönderme.
    static var networkDirection:Int { get{int("networkDirection",0,[0,1,2])} set{store.set(newValue,forKey:"networkDirection")} }
    static let intervals=[1,2,3,5]
    static var interval:Int { get{int("refreshInterval",3,intervals)} set{store.set(newValue,forKey:"refreshInterval")} }
    static var highlight:Bool { get{bool("highlight",true)} set{store.set(newValue,forKey:"highlight")} }
    static let thresholds=[70,80,90]
    static var cpuThreshold:Int { get{int("cpuThreshold",90,thresholds)} set{store.set(newValue,forKey:"cpuThreshold")} }
    static var showPanelOnLaunch:Bool { get{bool("showPanelOnLaunch",true)} set{store.set(newValue,forKey:"showPanelOnLaunch")} }
    static var historyEnabled:Bool { get{store.bool(forKey:"historyEnabled")} set{store.set(newValue,forKey:"historyEnabled")} }
    static var liveApps:Bool { get{bool("liveApps",true)} set{store.set(newValue,forKey:"liveApps")} }
}

/// Girişte açılma: macOS 13+ SMAppService. Kullanıcı açıkça seçmedikçe kaydedilmez.
enum LoginItem {
    static var enabled:Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval:Bool { SMAppService.mainApp.status == .requiresApproval }
    static func set(_ on:Bool) throws { if on {try SMAppService.mainApp.register()} else {try SMAppService.mainApp.unregister()} }
}

/// Ayarlar (1.6): panellerle aynı koyu monitör dili; az satır, kısa metin, her denetim tek iş yapar.
final class SettingsController:NSWindowController,NSWindowDelegate {
    private static let width:CGFloat=400
    var onChange:(()->Void)?
    var onHistoryChange:((Bool)->Void)?
    var onOpenHistory:(()->Void)?
    var onClose:(()->Void)?

    private let systemMode=PulseSegments(labels:[L("CPU","CPU"),L("RAM","RAM"),L("Simge","Icon")])
    private let networkMode=PulseSegments(labels:[L("Hız","Speed"),L("Bugün","Today"),L("Gizli","Off")])
    private let direction=PulseSegments(labels:[L("Büyük olan","Higher"),"↓","↑"])
    private let alert=PulseSegments(labels:[L("Kapalı","Off")]+Prefs.thresholds.map{"\($0)%"})
    private let interval=PulseSegments(labels:Prefs.intervals.map{"\($0) "+L("sn","s")})
    private let login=PulseSwitch()
    private let loginNote=NSTextField(wrappingLabelWithString:"")
    private let showOnLaunch=PulseSwitch()
    private let history=PulseSwitch()
    private var directionRow:NSView!
    private let root=NSStackView()

    init() {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:Self.width+40,height:480),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        window.title=L("Nabız · Ayarlar","Nabız · Settings");window.titleVisibility = .hidden;window.titlebarAppearsTransparent=true
        window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua);window.isMovableByWindowBackground=true
        let background=MonitorBackground();window.contentView=background
        super.init(window:window);window.delegate=self
        root.orientation = .vertical;root.alignment = .leading;root.spacing=14
        root.translatesAutoresizingMaskIntoConstraints=false;background.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:background.leadingAnchor,constant:20),root.topAnchor.constraint(equalTo:background.topAnchor,constant:40),root.widthAnchor.constraint(equalToConstant:Self.width)])

        for control in [systemMode,networkMode,direction,alert,interval] {control.target=self;control.action=#selector(changed);}
        for control in [login,showOnLaunch,history] {control.target=self}
        showOnLaunch.action=#selector(changed);login.action=#selector(toggleLogin);history.action=#selector(toggleHistory)

        let mark=NSImageView(image:NabizMark.image(size:24));mark.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([mark.widthAnchor.constraint(equalToConstant:24),mark.heightAnchor.constraint(equalToConstant:24)])
        let title=NSTextField(labelWithString:L("Ayarlar","Settings"));title.font = .systemFont(ofSize:18,weight:.bold);title.textColor=Vital.text
        let head=NSStackView(views:[mark,title]);head.spacing=10;head.alignment = .centerY
        root.addArrangedSubview(head);root.setCustomSpacing(18,after:head)

        directionRow=row(L("Ağ yönü","Network direction"),direction)
        root.addArrangedSubview(section(L("Menü çubuğu","Menu bar"),[
            row(L("Sistem öğesi","System item"),systemMode),
            row(L("Ağ öğesi","Network item"),networkMode),
            directionRow,
            row(L("Yüksek CPU uyarısı","High CPU alert"),alert,L("Değer eşiği geçince menü çubuğunda turuncu görünür.","The value turns orange in the menu bar above the threshold.")),
        ]))
        loginNote.font = .systemFont(ofSize:10.5);loginNote.textColor = .systemOrange
        root.addArrangedSubview(section(L("Genel","General"),[
            row(L("Yenileme","Refresh"),interval),
            row(L("Girişte aç","Open at login"),login),
            loginNote,
            row(L("Açılışta paneli göster","Show panel at launch"),showOnLaunch),
        ]))
        let open=PillButton(title:L("Geçmişi aç","Open History"),tip:L("Geçmiş penceresini aç","Open History window"),target:self,action:#selector(openHistory))
        root.addArrangedSubview(section(L("Geçmiş","History"),[
            row(L("Geçmişi kaydet","Record history"),history,L("Dakikada bir özet, 14 gün, yalnız bu Mac'te.","One summary per minute, 14 days, on this Mac only.")),
            open,
        ]))
        let version=(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String).map{" "+$0} ?? ""
        let footer=NSTextField(labelWithString:"Nabız\(version) · "+L("Veriler bu Mac'ten çıkmaz.","Your data never leaves this Mac."))
        footer.font = .systemFont(ofSize:10);footer.textColor=Vital.faint
        root.addArrangedSubview(footer)
        for view in root.arrangedSubviews {view.widthAnchor.constraint(equalToConstant:Self.width).isActive=true}
        load()
    }
    required init?(coder:NSCoder){fatalError()}

    private func section(_ title:String,_ rows:[NSView])->NSView {
        let card=Surface(radius:12)
        let stack=NSStackView(views:rows);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12
        stack.translatesAutoresizingMaskIntoConstraints=false;card.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:card.leadingAnchor,constant:14),stack.trailingAnchor.constraint(equalTo:card.trailingAnchor,constant:-14),stack.topAnchor.constraint(equalTo:card.topAnchor,constant:12),stack.bottomAnchor.constraint(equalTo:card.bottomAnchor,constant:-12)])
        for view in rows where !(view is PillButton) {view.widthAnchor.constraint(equalToConstant:Self.width-28).isActive=true}
        let outer=NSStackView(views:[caps(upper(title)),card]);outer.orientation = .vertical;outer.alignment = .leading;outer.spacing=6
        card.widthAnchor.constraint(equalToConstant:Self.width).isActive=true
        return outer
    }
    private func row(_ title:String,_ control:NSView,_ note:String?=nil)->NSView {
        let label=NSTextField(labelWithString:title);label.font = .systemFont(ofSize:12.5,weight:.medium);label.textColor=Vital.text
        let line=NSStackView(views:[label,NSView(),control]);line.orientation = .horizontal;line.alignment = .centerY;line.spacing=8
        control.setAccessibilityLabel(title)
        guard let note else {return line}
        let detail=NSTextField(wrappingLabelWithString:note);detail.font = .systemFont(ofSize:10.5);detail.textColor=Vital.faint
        let stack=NSStackView(views:[line,detail]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=3
        line.widthAnchor.constraint(equalToConstant:Self.width-28).isActive=true
        detail.widthAnchor.constraint(equalToConstant:Self.width-28).isActive=true
        return stack
    }

    func load() {
        systemMode.selectedSegment=Prefs.menuMode
        networkMode.selectedSegment=[2,0,1][Prefs.networkMode]
        direction.selectedSegment=Prefs.networkDirection
        directionRow.isHidden=Prefs.networkMode==0
        alert.selectedSegment=Prefs.highlight ? 1+(Prefs.thresholds.firstIndex(of:Prefs.cpuThreshold) ?? 2):0
        interval.selectedSegment=Prefs.intervals.firstIndex(of:Prefs.interval) ?? 2
        showOnLaunch.state=Prefs.showPanelOnLaunch ? .on:.off
        history.state=Prefs.historyEnabled ? .on:.off
        login.state=LoginItem.enabled || LoginItem.needsApproval ? .on:.off
        loginNote.stringValue=L("macOS onayı gerekiyor: Sistem Ayarları › Genel › Giriş Öğeleri.","macOS approval needed: System Settings › General › Login Items.")
        loginNote.isHidden = !LoginItem.needsApproval
        resizeToFit()
    }
    private func resizeToFit() {
        guard let window else {return}
        root.layoutSubtreeIfNeeded()
        let size=NSSize(width:Self.width+40,height:root.fittingSize.height+60)
        var frame=window.frameRect(forContentRect:NSRect(origin:.zero,size:size))
        frame.origin=NSPoint(x:window.frame.minX,y:window.frame.maxY-frame.height)
        if abs(frame.height-window.frame.height)>0.5 {window.setFrame(frame,display:true)}
    }
    @objc private func changed() {
        Prefs.menuMode=max(0,systemMode.selectedSegment)
        Prefs.networkMode=[1,2,0][max(0,networkMode.selectedSegment)]
        Prefs.networkDirection=max(0,direction.selectedSegment)
        Prefs.highlight=alert.selectedSegment>0
        if alert.selectedSegment>0 {Prefs.cpuThreshold=Prefs.thresholds[alert.selectedSegment-1]}
        Prefs.interval=Prefs.intervals[max(0,min(Prefs.intervals.count-1,interval.selectedSegment))]
        Prefs.showPanelOnLaunch=showOnLaunch.state == .on
        load();onChange?()
    }
    @objc private func toggleHistory(){Prefs.historyEnabled=history.state == .on;onHistoryChange?(Prefs.historyEnabled)}
    @objc private func openHistory(){onOpenHistory?()}
    @objc private func toggleLogin() {
        do {try LoginItem.set(login.state == .on)}
        catch {
            let alert=NSAlert();alert.messageText=L("Giriş öğesi değiştirilemedi","Couldn't change the login item");alert.informativeText=error.localizedDescription
            if let window {alert.beginSheetModal(for:window)}
        }
        load()
    }
    func windowDidBecomeKey(_ notification:Notification){load()}
    func windowWillClose(_ notification:Notification){onClose?()}
}
