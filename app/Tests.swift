import Foundation
import SQLite3

func runSelfTests() throws {
    var addresses:UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&addresses)==0 {
        defer {freeifaddrs(addresses)}
        var expected=Set<String>(),cursor=addresses
        while let item=cursor {
            let info=item.pointee
            if let address=info.ifa_addr,Int(address.pointee.sa_family)==Int(AF_LINK),let raw=info.ifa_name {
                let name=String(cString:raw)
                if name.hasPrefix("en") && info.ifa_flags & UInt32(IFF_UP) != 0 {expected.insert(name)}
            }
            cursor=info.ifa_next
        }
        let observed=Set((interfaceCounters() ?? [:]).keys.compactMap{$0.split(separator:"#").first.map(String.init)})
        precondition(expected.isSubset(of:observed),"Route parser omitted an active physical interface")
    }
    precondition(dominantTraffic(800000,2000)=="↓ 800KB/s")
    precondition(dominantTraffic(5000,1200000)=="↑ 1.2MB/s")
    precondition(compactSpeed(800)=="0.8KB/s")
    precondition(compactSpeed(1000000)=="1.0MB/s")
    precondition(compactSpeed(999600)=="1.0MB/s")
    precondition(compactSpeed(99960000)=="100MB/s")
    precondition(compactBytes(999600)=="1.0MB")
    precondition(compactBytes(99960000)=="100MB")
    var tracker=NetworkTracker()
    let start=Date()
    precondition(tracker.consume(["en0":Traffic(received:5_000_000_000,sent:100)],at:start).received==0)
    let a=tracker.consume(["en0":Traffic(received:5_000_000_300,sent:140)],at:start.addingTimeInterval(3))
    precondition(a.received==300 && a.sent==40 && a.down==100)
    let b=tracker.consume(["en0":Traffic(received:5_000_000_400,sent:150),"en1":Traffic(received:1_000_000_000_000,sent:20)],at:start.addingTimeInterval(6))
    precondition(b.received==100 && b.sent==10) // a newly connected interface is only primed
    let c=tracker.consume(["en1":Traffic(received:1_000_000_000_100,sent:25)],at:start.addingTimeInterval(9))
    precondition(c.received==100 && c.sent==5) // removing en0 cannot create a negative aggregate
    let d=tracker.consume(["en1":Traffic(received:2,sent:1)],at:start.addingTimeInterval(12))
    precondition(d.received==0 && d.sent==0) // reset or interface recreation
    precondition(tracker.consume(["en1":Traffic(received:99999,sent:20)],at:start.addingTimeInterval(120)).received==0)
    tracker.reset();precondition(tracker.consume(["en0":Traffic(received:99999,sent:20)],at:start.addingTimeInterval(123)).received==0)

    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("nabiz-tests-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) } // Only this named disposable fixture.
    let ledger=Ledger(directory:directory)
    ledger.add(NetworkDelta(received:300,sent:90,seconds:3),at:start)
    ledger.record(at:start,elapsed:3,high:true,temperature:80,apps:[AppLoad(name:"Synthetic App's Test",cpu:42)],enabled:true)
    ledger.flush();ledger.flush() // Idempotent; cannot duplicate accumulated seconds.
    ledger.record(at:start,elapsed:3,high:false,temperature:60,apps:[],enabled:true)
    let summary=ledger.summary(days:1)
    precondition(summary.seconds==6 && summary.highSeconds==3 && summary.maxTemp==80)
    precondition(summary.applications.first?.name=="Synthetic App's Test")
    precondition(summary.busiest?.hasSuffix(" · 3 "+L("sn","s"))==true)
    precondition(summary.hourly && summary.buckets.count==24 && summary.buckets.reduce(0){$0+$1.seconds}==6 && summary.buckets.reduce(0){$0+$1.high}==3)
    precondition(summary.traffic.received==300 && summary.traffic.sent==90)
    let week=ledger.summary(days:7)
    precondition(!week.hourly && week.buckets.count==7 && week.buckets.last?.seconds==6 && week.buckets.last?.traffic?.received==300)
    precondition(ledger.summary(days:14).buckets.count==14)
    let reopened=Ledger(directory:directory)
    precondition(reopened.totals[Ledger.day(start)]?.received==300)
    precondition(reopened.summary(days:7).seconds==6)
    let calendar=Calendar.current, midnight=calendar.startOfDay(for:start)
    let fresh=Ledger(directory:directory.appendingPathComponent("midnight"))
    fresh.add(NetworkDelta(received:100,sent:60,seconds:4),at:midnight.addingTimeInterval(2))
    precondition(fresh.totals[Ledger.day(midnight)]?.received==50)
    precondition(fresh.totals[Ledger.day(midnight.addingTimeInterval(-2))]?.received==50)
    let disabled=Ledger(directory:directory.appendingPathComponent("disabled"))
    disabled.record(at:start,elapsed:3,high:true,temperature:80,apps:[],enabled:false)
    precondition(disabled.summary(days:1).seconds==0)
    precondition(compactBytes(UInt64.max).count<=6)
    // A failed transaction must retain the sample and write it exactly once on retry.
    let retryDir=directory.appendingPathComponent("locked")
    let retry=Ledger(directory:retryDir)
    var lock:OpaquePointer?
    precondition(sqlite3_open(retryDir.appendingPathComponent("metrics.sqlite3").path,&lock)==SQLITE_OK)
    precondition(sqlite3_exec(lock,"BEGIN EXCLUSIVE",nil,nil,nil)==SQLITE_OK)
    retry.record(at:start,elapsed:3,high:true,temperature:81,apps:[],enabled:true)
    retry.add(NetworkDelta(received:123,sent:12,seconds:3),at:start)
    retry.flush();precondition(retry.error != nil)
    precondition(sqlite3_exec(lock,"ROLLBACK",nil,nil,nil)==SQLITE_OK);sqlite3_close(lock)
    retry.flush();retry.flush()
    precondition(retry.summary(days:1).seconds==3 && retry.error==nil)
    precondition(Ledger(directory:retryDir).totals[Ledger.day(start)]?.received==123)

    let target=directory.appendingPathComponent("unrelated")
    try Data("Unrelated file".utf8).write(to:target)
    let linkedDir=directory.appendingPathComponent("linked-db")
    try FileManager.default.createDirectory(at:linkedDir,withIntermediateDirectories:true)
    try FileManager.default.createSymbolicLink(at:linkedDir.appendingPathComponent("metrics.sqlite3"),withDestinationURL:target)
    precondition(Ledger(directory:linkedDir).error != nil)
    let preserved=try Data(contentsOf:target)
    precondition(preserved==Data("Unrelated file".utf8))
    let dirLink=directory.appendingPathComponent("directory-link")
    try FileManager.default.createSymbolicLink(at:dirLink,withDestinationURL:retryDir)
    precondition(Ledger(directory:dirLink).error != nil)
    let hardDir=directory.appendingPathComponent("hard-link")
    try FileManager.default.createDirectory(at:hardDir,withIntermediateDirectories:true)
    try FileManager.default.linkItem(at:target,to:hardDir.appendingPathComponent("metrics.sqlite3"))
    precondition(Ledger(directory:hardDir).error != nil)
    let attrs=try FileManager.default.attributesOfItem(atPath:retryDir.path)
    precondition((attrs[.posixPermissions] as? NSNumber)?.intValue==0o700)
    let fileAttrs=try FileManager.default.attributesOfItem(atPath:retryDir.appendingPathComponent("metrics.sqlite3").path)
    precondition((fileAttrs[.posixPermissions] as? NSNumber)?.intValue==0o600)

    var clock=NetworkTracker()
    _=clock.consume(["en0":Traffic()],at:start,uptime:100)
    let corrected=clock.consume(["en0":Traffic(received:300,sent:0)],at:start.addingTimeInterval(-3600),uptime:103)
    precondition(corrected.down==100)
    precondition(saturatedSum(UInt64.max,1)==UInt64.max)
    precondition(compactSpeed(.nan)=="—" && dominantTraffic(.infinity,nil)=="—")
    precondition(dominantTraffic(Double(UInt64.max),0,total:true)=="↓ 999+TB")
    precondition(safeProcessName("App\n\tTest")=="AppTest")
    let sideDir=directory.appendingPathComponent("sidecar-link")
    try FileManager.default.createDirectory(at:sideDir,withIntermediateDirectories:true)
    try FileManager.default.createSymbolicLink(at:sideDir.appendingPathComponent("metrics.sqlite3-journal"),withDestinationURL:target)
    precondition(Ledger(directory:sideDir).error != nil)
    precondition((try? Data(contentsOf:target))==preserved)
    let corruptDir=directory.appendingPathComponent("corrupt")
    try FileManager.default.createDirectory(at:corruptDir,withIntermediateDirectories:true)
    try preserved.write(to:corruptDir.appendingPathComponent("metrics.sqlite3"))
    precondition(Ledger(directory:corruptDir).error != nil)

    // Independent oracle: libproc/Mach counters must agree with getrusage seconds.
    func sampledOwnCPU()->Double {
        var entries=Array(repeating:MBProcess(),count:2048)
        let count=entries.withUnsafeMutableBufferPointer{mb_processes($0.baseAddress,Int32($0.count))}
        precondition(count>0)
        return Double(entries.prefix(Int(count)).first{$0.pid==getpid()}!.cpu_ns)/1e9
    }
    let sampledStart=sampledOwnCPU(),ownStart=mb_own_cpu_seconds()
    while mb_own_cpu_seconds()-ownStart<0.05 {}
    let sampledSeconds=sampledOwnCPU()-sampledStart,ownSeconds=mb_own_cpu_seconds()-ownStart
    precondition(abs(sampledSeconds/ownSeconds-1)<0.2,"Mach ticks were not converted to nanoseconds")
    let importedDir=directory.appendingPathComponent("imported")
    let source=retryDir.appendingPathComponent("metrics.sqlite3")
    let receipt=try copyLegacyRecords(source:source,directory:importedDir)
    let originalBytes=try Data(contentsOf:source),backupBytes=try Data(contentsOf:receipt.backup)
    precondition(originalBytes==backupBytes)
    precondition(Ledger(directory:importedDir).totals[Ledger.day(start)]?.received==123)
    do {_=try copyLegacyRecords(source:source,directory:importedDir);preconditionFailure("Import overwrote a database")} catch ImportFailure.destinationExists {}
    do {_=try copyLegacyRecords(source:corruptDir.appendingPathComponent("metrics.sqlite3"),directory:directory.appendingPathComponent("bad-import"));preconditionFailure("Imported invalid bytes")} catch ImportFailure.invalidDatabase {}
    print("PASS: 64-bit network deltas, interface changes/reset, restart/gap, midnight split, persistent totals, history opt-in, idempotent history, retry after lock, safe storage paths/permissions, monotonic rates and safe app names")
}
