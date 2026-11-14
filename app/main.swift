import AppKit
import Foundation

struct Snapshot {
    var cpu: Double?
    var gpu: Double?
    var memoryValid: Bool
    var ramUsed: Double
    var ramTotal: Double
    var compressed: Double
    var swap: Double
    var pressure: Int
    var temperature: Double?
    var fans: [(Double?, Double?)]
    var diskFree: Double?
    var download: Double?
    var upload: Double?
    var today: Traffic
    var week: Traffic
    var cpuUser: Double?
    var cpuSystem: Double?
    /// SMC sıcaklık sensörleri okunabiliyor mu (App Store sürümünde hiç açılmaz).
    var sensors: Bool
    /// Yalnız sistem paneli açıkken dolar; nil ilk karşılaştırma bekleniyor demektir.
    var liveApps: [AppLoad]?
    var storageError: String?
    var date: Date
}

func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
func gib(_ value: Double) -> String { String(format: "%.1f", value / 1_073_741_824) }
func rate(_ value: Double?) -> String { compactSpeed(value).replacingOccurrences(of:"/s",with:L("/sn","/s")) }
func finiteCount(_ value:Double)->UInt64 {
    guard value.isFinite,value>0 else {return 0}
    return value>=Double(UInt64.max) ? UInt64.max:UInt64(value)
}

func compactBytes(_ count:UInt64)->String {
    let units=["B","KB","MB","GB","TB"];var value=Double(count),index=0
    while value>=1000 && index<4 {value/=1000;index+=1}
    if index>0 && value>=999.5 && index<4 {value/=1000;index+=1}
    if value>=999.5 && index==4{return "999+TB"}
    return value>=99.95 || index==0 ? String(format:"%.0f%@",value,units[index]):String(format:"%.1f%@",value,units[index])
}
func compactSpeed(_ value:Double?)->String {
    guard let value=value,value.isFinite else{return "—"}
    var v=max(0,value)/1000,index=0
    let units=["KB/s","MB/s","GB/s","TB/s"]
    while v>=999.5 && index<3 {v/=1000;index+=1}
    if index==3 {v=min(999,v)}
    let decimals=index==0 ? v>0 && v<9.95 : v<99.95
    return String(format:decimals ? "%.1f%@":"%.0f%@",v,units[index])
}
func dominantTraffic(_ down:Double?,_ up:Double?,total:Bool=false)->String {
    let down=down.flatMap{$0.isFinite && $0>=0 ? $0:nil},up=up.flatMap{$0.isFinite && $0>=0 ? $0:nil}
    guard down != nil || up != nil else{return "—"}
    let received=down ?? 0,sent=up ?? 0,isUpload=sent>received
    let value=max(received,sent)
    return (isUpload ? "↑ ":"↓ ")+(total ? compactBytes(finiteCount(value)):compactSpeed(value))
}

func pressureText(_ value: Int) -> String {
    switch value { case 1: return L("Normal","Normal"); case 2: return L("Artmış","Elevated"); case 4: return L("Yüksek","High"); default: return L("Okunamadı","Unavailable") }
}
func thermalLevel() -> Int {
    switch ProcessInfo.processInfo.thermalState { case .nominal: return 0; case .fair: return 1; case .serious: return 2; case .critical: return 3; @unknown default: return 0 }
}
func thermalText() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return L("Normal","Normal"); case .fair: return L("Hafif artmış","Slightly elevated"); case .serious: return L("Yüksek","High"); case .critical: return L("Kritik","Critical"); @unknown default: return L("Bilinmiyor","Unknown")
    }
}

final class Reader {
    private var previous: MBHost?
    private var lastDiskSample:TimeInterval = -.infinity
    private var diskFree:Double?
    private let homeVolume=URL(fileURLWithPath:NSHomeDirectory())
    private var network=NetworkTracker()
    private let ledger:Ledger?
    private let processes=ProcessSampler()
    private var lastProcessSample:TimeInterval = -.infinity
    private var apps:[AppLoad]=[]
    private let liveSampler=ProcessSampler()
    private var lastLiveSample:TimeInterval = -.infinity
    private var live:[AppLoad]?
    /// Sistem paneli açıkken true; kapanınca süreç taraması durur ve önceki sayaçlar bırakılır.
    var liveApps=false { didSet { if !liveApps { liveSampler.reset();live=nil;lastLiveSample = -.infinity } } }
    var historyEnabled=Prefs.historyEnabled {
        didSet { if !historyEnabled { processes.reset();apps=[];lastProcessSample = -.infinity;ledger?.flush() } }
    }
    private var connection: UInt32 = 0
    private var temperatureKeys: [String] = []
    private var fanCount = 0
    private var maxima: [Double?] = []

    init(storesData:Bool=true) { ledger=storesData ? Ledger():nil;reconnect() }
    func flush(){ledger?.flush()}
    func history(days:Int)->HistorySummary { ledger?.summary(days:days) ?? HistorySummary() }
    deinit { mb_smc_close(connection) }
    private func value(_ key: String) -> Double? {
        var v = 0.0
        return key.withCString { mb_smc_read(connection, $0, &v) } ? v : nil
    }
    func reconnect() {
        mb_smc_close(connection)
        #if NABIZ_APPSTORE
        connection = 0 // Mac App Store sürümü SMC'ye hiç bağlanmaz; sıcaklık/fan yerine macOS ısı durumu kullanılır.
        #else
        connection = mb_smc_open()
        #endif
        previous = nil; lastDiskSample = -.infinity; network.reset();processes.reset();lastProcessSample = -.infinity;apps=[]
        liveSampler.reset();live=nil;lastLiveSample = -.infinity
        let count = value("FNum") ?? 0
        fanCount = (count >= 0 && count <= 8) ? Int(count) : 0
        maxima = (0..<fanCount).map { value("F\($0)Mx") }
        // Known CPU sensor keys. Missing keys are never substituted with guesses.
        let keys = ["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e", "TC0P"]
        temperatureKeys = keys.filter { value($0).map { $0 > 0 && $0 < 130 } ?? false }
    }
    func sample() -> Snapshot {
        let now = Date(), host = mb_host_read()
        var cpu: Double?, user: Double?, system: Double?, down: Double?, up: Double?
        if let old = previous {
            // The underlying kernel counters are 32 bit. Reset/wrap means re-prime.
            if host.cpu_valid && old.cpu_valid && host.user_ticks >= old.user_ticks && host.system_ticks >= old.system_ticks && host.idle_ticks >= old.idle_ticks && host.nice_ticks >= old.nice_ticks {
                let busy = host.user_ticks - old.user_ticks + host.system_ticks - old.system_ticks + host.nice_ticks - old.nice_ticks
                let total = busy + host.idle_ticks - old.idle_ticks
                if total > 0 {
                    cpu = min(100, max(0, Double(busy) / Double(total) * 100))
                    user = min(100, Double(host.user_ticks - old.user_ticks + host.nice_ticks - old.nice_ticks) / Double(total) * 100)
                    system = min(100, Double(host.system_ticks - old.system_ticks) / Double(total) * 100)
                }
            }
        }
        let uptime=ProcessInfo.processInfo.systemUptime
        let traffic=network.consume(interfaceCounters(),at:now,uptime:uptime)
        ledger?.add(traffic,at:now)
        down=traffic.down;up=traffic.up

        previous = host
        let temperatures = temperatureKeys.compactMap(value).filter { $0 > 0 && $0 < 130 }
        let fans: [(Double?, Double?)] = (0..<fanCount).map { index in
            let rpm = value("F\(index)Ac").flatMap { $0 >= 0 && $0 < 20_000 ? $0 : nil }
            return (rpm, maxima[index])
        }
        if uptime-lastDiskSample>=60 {
            let volume=try? homeVolume.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
            diskFree=volume?.volumeAvailableCapacityForImportantUsage.map(Double.init);lastDiskSample=uptime
        }
        if historyEnabled && uptime-lastProcessSample>=30 {
            apps=processes.sample(at:ProcessInfo.processInfo.systemUptime);lastProcessSample=uptime
        }
        if liveApps && uptime-lastLiveSample>=2.5 {
            let first=lastLiveSample == -.infinity
            let result=liveSampler.sample(at:uptime);lastLiveSample=uptime
            live=first ? nil:result
        }
        #if NABIZ_APPSTORE
        let high=thermalLevel()>=1
        #else
        let high=fans.contains{($0.0 ?? 0)>=3500}
        #endif
        ledger?.record(at:now,elapsed:traffic.seconds,high:high,temperature:temperatures.max(),apps:apps,enabled:historyEnabled)
        ledger?.flushIfNeeded(uptime:uptime)
        let today=ledger?.totals[Ledger.day(now)] ?? Traffic()
        var week=Traffic()
        for offset in 0..<7 {
            guard let day=Calendar.current.date(byAdding:.day,value:-offset,to:now),let value=ledger?.totals[Ledger.day(day)] else {continue}
            week.received=saturatedSum(week.received,value.received);week.sent=saturatedSum(week.sent,value.sent)
        }
        let gpu = mb_gpu_read()
        return Snapshot(cpu: cpu, gpu: gpu >= 0 ? gpu : nil, memoryValid: host.memory_valid, ramUsed: Double(host.ram_used), ramTotal: Double(host.ram_total), compressed: Double(host.ram_compressed), swap: Double(host.swap_used), pressure: Int(host.pressure), temperature: temperatures.max(), fans: fans, diskFree: diskFree, download: down, upload: up, today:today, week:week, cpuUser:user, cpuSystem:system, sensors:!temperatureKeys.isEmpty, liveApps:liveApps ? live:nil, storageError:ledger?.error, date: now)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let reader = Reader()
    let queue = DispatchQueue(label: "local.nabiz.metrics", qos: .utility,autoreleaseFrequency:.workItem)
    var timer: DispatchSourceTimer?
    private var sampleGeneration=0
    let systemPanel = SystemPanel()
    let networkPanel = NetworkPanel()
    let systemPopover = NSPopover()
    let networkPopover = NSPopover()
    var status: NSStatusItem!
    var networkStatus: NSStatusItem!
    let menuMeter=MenuMeter()
    let networkMeter=MenuMeter()
    var last: Snapshot?
    var traces=Traces()
    var paused = false
    var historyWindow:HistoryController?
    var settingsWindow:SettingsController?
    var lastHistoryRefresh=Date.distantPast
    private var quiet:Bool { CommandLine.arguments.contains("--benchmark") || CommandLine.arguments.contains("--menu-layout") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Accessory apps have no default menu, so standard window shortcuts need wiring.
        let mainMenu=NSMenu(),appItem=NSMenuItem(),appMenu=NSMenu()
        mainMenu.addItem(appItem);appItem.submenu=appMenu
        let settingsItem=appMenu.addItem(withTitle:"Ayarlar…",action:#selector(showSettings),keyEquivalent:",");settingsItem.target=self
        appMenu.addItem(withTitle:"Pencereyi kapat",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        let quitItem=appMenu.addItem(withTitle:"Nabız’dan çık",action:#selector(quit),keyEquivalent:"q");quitItem.target=self
        NSApp.mainMenu=mainMenu
        networkMeter.section = .network
        networkStatus=makeStatus(networkMeter,name:"NabizNetwork",label:L("Nabız · ağ kullanımı","Nabız · network usage"))
        status=makeStatus(menuMeter,name:"NabizSystem",label:L("Nabız · sistem kullanımı","Nabız · system usage"))
        let actions=PanelActions(history:{[weak self] in self?.showHistory()},settings:{[weak self] in self?.showSettings()},pause:{[weak self] in self?.togglePause()},quit:{NSApp.terminate(nil)})
        for (popover,panel) in [(systemPopover,systemPanel as BasePanel),(networkPopover,networkPanel as BasePanel)] {
            panel.actions=actions;popover.contentViewController=panel;popover.behavior = .transient;popover.animates=false;popover.delegate=self;popover.appearance=NSAppearance(named:.darkAqua)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(waking), name: NSWorkspace.didWakeNotification, object: nil)
        renderStatus(); start()
        if CommandLine.arguments.contains("--menu-layout") {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) {
                for (name,item) in [("system",self.status!), ("network",self.networkStatus!)] {
                    if let button=item.button {
                        print("\(name): requested=\(item.length), button=\(button.frame), bounds=\(button.bounds), window=\(String(describing:button.window?.frame)), view=\(button.subviews.map{String(describing:$0.frame)}), cell=\(String(describing:button.cell?.cellSize))")
                    }
                }
                NSApp.terminate(nil)
            }
        } else if CommandLine.arguments.contains("--benchmark") {
            // Explicit QA mode only: measure steady menu-only CPU/physical footprint.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let start = mb_own_cpu_seconds(), time = Date()
                let duration=min(120,max(20,Double(ProcessInfo.processInfo.environment["NABIZ_BENCHMARK_SECONDS"] ?? "20") ?? 20))
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    let cpu = (mb_own_cpu_seconds() - start) / Date().timeIntervalSince(time) * 100
                    print(String(format: "{\"phase\":\"menu_only_%.0fs\",\"cpu_percent_one_core\":%.3f,\"physical_footprint_MiB\":%.2f}", duration,cpu, Double(mb_own_footprint()) / 1_048_576))
                    NSApp.terminate(nil)
                }
            }
        } else if let index=CommandLine.arguments.firstIndex(of:"--open"),index+1<CommandLine.arguments.count {
            // Geliştirici önizlemesi: belirli paneli/pencereyi açar.
            let target=CommandLine.arguments[index+1]
            DispatchQueue.main.asyncAfter(deadline:.now()+3.5) { [weak self] in
                switch target { case "network": self?.showPanel(network:true); case "settings": self?.showSettings(); case "history": self?.showHistory(); default: self?.showPanel(network:false) }
            }
        } else if Prefs.showPanelOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPanel(network:false) }
        }
    }
    private func start() {
        sampleGeneration+=1
        let generation=sampleGeneration
        timer?.cancel()
        let interval=Prefs.interval
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(interval), leeway: .milliseconds(interval*200))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let sample = self.reader.sample()
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.paused,self.sampleGeneration==generation else { return }
                self.last = sample;self.traces.add(sample); self.renderStatus()
                if self.systemPopover.isShown { self.systemPanel.update(sample,traces:self.traces) }
                if self.networkPopover.isShown { self.networkPanel.update(sample,traces:self.traces) }
                if self.historyWindow?.window?.isVisible == true && sample.date.timeIntervalSince(self.lastHistoryRefresh)>=30 {
                    self.lastHistoryRefresh=sample.date;self.historyWindow?.refresh()
                }
            }
        }
        self.timer = timer; timer.resume()
    }
    private func networkText()->String {
        let total=Prefs.networkMode==2
        var down=total ? last.map{Double($0.today.received)} : last?.download
        var up=total ? last.map{Double($0.today.sent)} : last?.upload
        switch Prefs.networkDirection { case 1: up=nil; if down==nil && last != nil {down=0}; case 2: down=nil; if up==nil && last != nil {up=0}; default: break }
        if Prefs.networkDirection==2,let up {
            return "↑ "+(total ? compactBytes(finiteCount(up)):compactSpeed(up))
        }
        return dominantTraffic(down,up,total:total)
    }
    private func renderStatus() {
        let menuMode=Prefs.menuMode,networkMode=Prefs.networkMode
        let value: String
        var hot=false
        if menuMode==1,let sample=last {
            value=percent(sample.memoryValid && sample.ramTotal>0 ? sample.ramUsed/sample.ramTotal*100:nil)
            hot=Prefs.highlight && sample.pressure>=2
        } else {
            value=percent(last?.cpu)
            hot=Prefs.highlight && (last?.cpu ?? 0)>=Double(Prefs.cpuThreshold)
        }
        let traffic=networkText()
        menuMeter.level=menuMode==1 ? last.flatMap{$0.memoryValid && $0.ramTotal>0 ? $0.ramUsed/$0.ramTotal*100:nil} : last?.cpu
        menuMeter.mode=menuMode;menuMeter.metric=value;menuMeter.paused=paused;menuMeter.alert=hot && !paused
        if status.length != menuMeter.preferredWidth {status.length=menuMeter.preferredWidth}
        networkMeter.traffic=traffic;networkMeter.paused=paused
        if networkStatus.isVisible != (networkMode != 0) { networkStatus.isVisible=networkMode != 0 }
        let primary=paused ? L("Duraklatıldı","Paused"):menuMode==2 ? "Nabız":"\(menuMode==1 ? "RAM":"CPU") \(value)"
        status.button?.setAccessibilityValue(primary)
        networkStatus.button?.setAccessibilityValue((networkMode==2 ? L("Bugün ölçülen","Measured today"):L("Anlık hız","Current speed"))+" · "+traffic)
        if let sample=last {
            let systemTip="CPU \(percent(sample.cpu)) · RAM \(gib(sample.ramUsed))/\(gib(sample.ramTotal)) GiB\n"+L("Tıkla: sistem paneli · Sağ tık: seçenekler","Click: system panel · Right-click: options")
            let networkTip=L("İndirme","Download")+" \(compactSpeed(sample.download)) · "+L("Gönderme","Upload")+" \(compactSpeed(sample.upload))\n"+L("Bugün","Today")+" ↓ \(compactBytes(sample.today.received)) ↑ \(compactBytes(sample.today.sent))\n"+L("Tıkla: ağ paneli · Sağ tık: seçenekler","Click: network panel · Right-click: options")
            if status.button?.toolTip != systemTip {status.button?.toolTip=systemTip}
            if networkStatus.button?.toolTip != networkTip {networkStatus.button?.toolTip=networkTip}
        }
    }

    private func makeStatus(_ meter:MenuMeter,name:String,label:String)->NSStatusItem {
        let item=NSStatusBar.system.statusItem(withLength:meter.preferredWidth)
        item.autosaveName=name
        if let button=item.button {
            meter.frame=button.bounds;meter.autoresizingMask=[.width,.height];button.addSubview(meter)
            button.target=self;button.action=#selector(clicked(_:));button.sendAction(on:[.leftMouseUp,.rightMouseUp])
            button.setAccessibilityLabel(label)
        }
        return item
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !quiet,historyWindow?.window?.isVisible != true,settingsWindow?.window?.isVisible != true,!systemPopover.isShown,!networkPopover.isShown else {return}
        // Finder'dan yeniden açma: sistem paneli.
        showPanel(network:false)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DispatchQueue.main.async { [weak self] in self?.showPanel(network:false) }
        return false
    }
    private func showPanel(network:Bool) {
        let popover=network ? networkPopover:systemPopover
        let other=network ? systemPopover:networkPopover
        if other.isShown {other.performClose(nil)}
        let item:NSStatusItem=network && networkStatus.isVisible ? networkStatus:status
        guard !popover.isShown,let button=item.button else {return}
        if network {
            if let sample=last {networkPanel.update(sample,traces:traces)} else {_ = networkPanel.view;networkPanel.fitSize()}
            networkPanel.setPaused(paused)
        } else {
            queue.async{[weak self] in self?.reader.liveApps=true}
            if let sample=last {systemPanel.update(sample,traces:traces)} else {_ = systemPanel.view;systemPanel.fitSize()}
            systemPanel.setPaused(paused)
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    func popoverDidClose(_ notification: Notification) {
        if (notification.object as? NSPopover) === systemPopover { queue.async{[weak self] in self?.reader.liveApps=false} }
    }
    @objc private func clicked(_ sender:NSStatusBarButton) {
        let network=sender === networkStatus.button
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(network ? networkStatus:status,network:network); return }
        let popover=network ? networkPopover:systemPopover
        if popover.isShown { popover.performClose(nil) } else { showPanel(network:network) }
    }
    private func choice(_ title:String,_ tag:Int,_ selected:Bool,_ action:Selector)->NSMenuItem {
        let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;item.tag=tag;item.state=selected ? .on:.off;return item
    }
    private func optionsMenu(network:Bool) -> NSMenu {
        let menu = NSMenu()
        if network {
            menu.addItem(choice(L("Anlık hız","Current speed"),1,Prefs.networkMode==1,#selector(changeNetwork(_:))))
            menu.addItem(choice(L("Bugünkü toplam","Today's total"),2,Prefs.networkMode==2,#selector(changeNetwork(_:))))
            menu.addItem(.separator())
            for (index,title) in [L("Hangisi büyükse","Whichever is higher"),L("Yalnız indirme ↓","Download only ↓"),L("Yalnız gönderme ↑","Upload only ↑")].enumerated() {
                menu.addItem(choice(title,index,Prefs.networkDirection==index,#selector(changeDirection(_:))))
            }
            menu.addItem(.separator())
            menu.addItem(choice(L("Ağ öğesini gizle","Hide network item"),0,false,#selector(changeNetwork(_:))))
        } else {
            for (index, title) in [L("CPU yüzdesi","CPU percentage"),L("RAM yüzdesi","RAM percentage"),L("Kısa N simgesi","Compact N icon")].enumerated() {
                menu.addItem(choice(title,index,Prefs.menuMode==index,#selector(changeMode(_:))))
            }
            if Prefs.networkMode==0 {
                menu.addItem(.separator())
                menu.addItem(choice(L("Ağ öğesini göster","Show network item"),1,false,#selector(changeNetwork(_:))))
            }
        }
        menu.addItem(.separator())
        let history=NSMenuItem(title:L("Geçmiş…","History…"),action:#selector(showHistory),keyEquivalent:"");history.target=self;menu.addItem(history)
        let settings=NSMenuItem(title:L("Ayarlar…","Settings…"),action:#selector(showSettings),keyEquivalent:",");settings.target=self;menu.addItem(settings)
        let pause = NSMenuItem(title: paused ? L("İzlemeyi sürdür","Resume monitoring") : L("İzlemeyi duraklat","Pause monitoring"), action: #selector(togglePause), keyEquivalent: "")
        pause.target = self; menu.addItem(pause)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("Nabız’dan çık","Quit Nabız"), action: #selector(quit), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        return menu
    }
    private func showMenu(_ item:NSStatusItem,network:Bool) {
        systemPopover.performClose(nil);networkPopover.performClose(nil)
        item.menu = optionsMenu(network:network); item.button?.performClick(nil); item.menu = nil
    }
    private func preferencesChanged(restart:Bool) {
        renderStatus();settingsWindow?.load()
        if networkPopover.isShown && Prefs.networkMode==0 {networkPopover.performClose(nil)}
        if systemPopover.isShown,let last {systemPanel.update(last,traces:traces)}
        if restart && !paused {traces.clear();start()}
    }
    @objc private func changeNetwork(_ sender:NSMenuItem){Prefs.networkMode=sender.tag;preferencesChanged(restart:false)}
    @objc private func changeDirection(_ sender:NSMenuItem){Prefs.networkDirection=sender.tag;preferencesChanged(restart:false)}
    @objc private func changeMode(_ sender: NSMenuItem) { Prefs.menuMode = sender.tag; preferencesChanged(restart:false) }
    @objc private func showSettings() {
        if settingsWindow==nil {
            let controller=SettingsController()
            var interval=Prefs.interval
            controller.onChange = { [weak self] in
                let restart=interval != Prefs.interval;interval=Prefs.interval
                self?.preferencesChanged(restart:restart)
            }
            controller.onHistoryChange = { [weak self] enabled in self?.setHistory(enabled) }
            controller.onOpenHistory = { [weak self] in self?.showHistory() }
            controller.onClose = { [weak self] in DispatchQueue.main.async {self?.settingsWindow=nil} }
            settingsWindow=controller
            controller.window?.center()
        }
        systemPopover.performClose(nil);networkPopover.performClose(nil)
        NSApp.activate(ignoringOtherApps:true);settingsWindow?.showWindow(nil);settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    private func setHistory(_ enabled:Bool) {
        Prefs.historyEnabled=enabled
        queue.async { [weak self] in self?.reader.historyEnabled=enabled }
        settingsWindow?.load();historyWindow?.refresh()
    }
    @objc private func showHistory(){
        if historyWindow==nil {
            let controller=HistoryController()
            controller.onToggle = { [weak self] enabled in self?.setHistory(enabled) }
            controller.onClose = { [weak self] in DispatchQueue.main.async {self?.historyWindow=nil} }
            controller.onRefresh = { [weak self] days in self?.refreshHistory(days:days) }
            historyWindow=controller
            controller.window?.center()
        }
        systemPopover.performClose(nil);networkPopover.performClose(nil)
        historyWindow?.showWindow(nil);historyWindow?.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);historyWindow?.refresh()
    }
    private func refreshHistory(days:Int){
        queue.async { [weak self] in
            guard let self=self else{return};let data=self.reader.history(days:days);let recording=self.reader.historyEnabled
            DispatchQueue.main.async {self.historyWindow?.display(data,recording:recording)}
        }
    }
    @objc private func togglePause() {
        paused.toggle()
        if paused { sampleGeneration+=1;timer?.cancel(); timer = nil; queue.async{[weak self] in self?.reader.flush()} }
        else { queue.async { [weak self] in self?.reader.reconnect() }; traces.clear(); start() }
        systemPanel.setPaused(paused);networkPanel.setPaused(paused)
        renderStatus()
    }
    @objc private func sleeping() { sampleGeneration+=1;timer?.cancel(); timer = nil;queue.async{[weak self] in self?.reader.flush()} }
    @objc private func waking() {
        guard !paused else { return }; queue.async { [weak self] in self?.reader.reconnect() };traces.clear(); start()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { timer?.cancel(); timer = nil;queue.sync{reader.flush()} }
}

if CommandLine.arguments.contains("--self-test") {
    try runSelfTests()
} else if CommandLine.arguments.contains("--import-legacy") {
    do {try importLegacyRecordsInteractively()} catch {fputs(error.localizedDescription+"\n",stderr);exit(1)}
} else if let index=CommandLine.arguments.firstIndex(of:"--sandbox-test"),index+1<CommandLine.arguments.count {
    try runSandboxChecks(outsidePath:CommandLine.arguments[index+1])
} else if CommandLine.arguments.contains("--sample") {
    let reader = Reader(storesData:false); _ = reader.sample(); Thread.sleep(forTimeInterval: 1)
    let s = reader.sample()
    let output: [String: Any] = ["cpu": s.cpu as Any? ?? NSNull(), "gpu": s.gpu as Any? ?? NSNull(), "ramUsedGiB": s.ramUsed / 1_073_741_824, "ramTotalGiB": s.ramTotal / 1_073_741_824, "pressure": pressureText(s.pressure), "cpuSensorMaxC": s.temperature as Any? ?? NSNull(), "fanRPM": s.fans.map { $0.0 as Any? ?? NSNull() }, "diskFreeGiB": s.diskFree.map { $0 / 1_073_741_824 } as Any? ?? NSNull()]
    let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]); print(String(data: data, encoding: .utf8)!)
} else {
    let app = NSApplication.shared
    if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.nabiz.monitor").contains(where: { $0.processIdentifier != getpid() }) { exit(0) }
    let delegate = AppDelegate(); app.delegate = delegate; withExtendedLifetime(delegate) { app.run() }
}
