import Foundation
import SQLite3
import Darwin

func saturatedSum(_ a:UInt64,_ b:UInt64)->UInt64 {let (value,overflow)=a.addingReportingOverflow(b);return overflow ? UInt64.max:value}
func safeProcessName(_ name:String)->String {
    let clean=String(String.UnicodeScalarView(name.unicodeScalars.filter{!CharacterSet.controlCharacters.contains($0)})).prefix(64)
    return clean.isEmpty ? L("Adsız süreç","Unnamed process"):String(clean)
}

struct Traffic: Codable { var received: UInt64 = 0; var sent: UInt64 = 0 }
struct NetworkDelta {
    var received: UInt64 = 0; var sent: UInt64 = 0
    var seconds: Double = 0
    var down: Double? { seconds > 0 ? Double(received)/seconds : nil }
    var up: Double? { seconds > 0 ? Double(sent)/seconds : nil }
}
struct NetworkTracker {
    var previous: [String: Traffic]?
    var time: Date?
    private var tick:TimeInterval?
    mutating func reset() { previous=nil; time=nil;tick=nil }
    mutating func consume(_ current: [String:Traffic]?, at now:Date,uptime:TimeInterval?=nil) -> NetworkDelta {
        guard let current=current else { reset(); return NetworkDelta() }
        defer { previous=current; time=now;tick=uptime }
        guard let old=previous, let before=time else { return NetworkDelta() }
        let elapsed=uptime.flatMap{current in tick.map{current-$0}} ?? now.timeIntervalSince(before)
        guard elapsed>0 && elapsed<30 else { return NetworkDelta() }
        var delta=NetworkDelta(seconds:elapsed)
        for (name,value) in current {
            guard let prior=old[name] else { continue }
            if value.received>=prior.received { delta.received = saturatedSum(delta.received,value.received-prior.received) }
            if value.sent>=prior.sent { delta.sent = saturatedSum(delta.sent,value.sent-prior.sent) }
        }
        return delta
    }
}
func interfaceCounters() -> [String:Traffic]? {
    var entries=Array(repeating:MBInterface(),count:32)
    let count=entries.withUnsafeMutableBufferPointer { mb_interfaces($0.baseAddress,Int32($0.count)) }
    guard count>=0 else { return nil }
    var result:[String:Traffic]=[:]
    for entry in entries.prefix(Int(count)) {
        let name=withUnsafeBytes(of:entry.name) { String(cString:$0.bindMemory(to:CChar.self).baseAddress!) }
        result[name+"#"+String(entry.index)]=Traffic(received:entry.received,sent:entry.sent)
    }
    return result
}
struct AppLoad: Codable { var name:String; var cpu:Double }
final class ProcessSampler {
    private var previous:[Int32:(UInt64,UInt64)]=[:]
    private var time:TimeInterval?
    func reset() { previous=[:]; time=nil }
    func sample(at now:TimeInterval) -> [AppLoad] {
        var entries=Array(repeating:MBProcess(),count:2048)
        let count=entries.withUnsafeMutableBufferPointer { mb_processes($0.baseAddress,Int32($0.count)) }
        guard count>=0 else { reset();return [] }
        var next:[Int32:(UInt64,UInt64)]=[:], loads:[String:Double]=[:]
        let elapsed=time.map { now-$0 } ?? 0
        for entry in entries.prefix(Int(count)) {
            next[entry.pid]=(entry.start,entry.cpu_ns)
            guard let old=previous[entry.pid], old.0==entry.start, entry.cpu_ns>=old.1, elapsed>0, elapsed<90 else { continue }
            let cpu=Double(entry.cpu_ns-old.1)/1e9/elapsed*100
            guard cpu>=5 else { continue }
            let name=withUnsafeBytes(of:entry.name) { String(cString:$0.bindMemory(to:CChar.self).baseAddress!) }
            loads[name,default:0]+=cpu
        }
        previous=next;time=now
        return loads.map { AppLoad(name:$0.key,cpu:$0.value) }.sorted { $0.cpu>$1.cpu }.prefix(3).map{$0}
    }
}
struct HistoryBucket {
    var start:Date;var seconds:Double=0;var high:Double=0;var maxTemp:Double?
    var traffic:Traffic?
}
struct HistorySummary {
    var seconds:Double=0;var highSeconds:Double=0;var maxTemp:Double?
    var applications:[AppLoad]=[];var minutes=0;var busiest:String?;var storageError:String?
    /// 24 hourly buckets for one day, otherwise one bucket per local day.
    var buckets:[HistoryBucket]=[];var hourly=true
    /// Traffic measured by Nabız in the selected local days (kept even when load history is off).
    var traffic=Traffic()
}
private struct MinuteRecord {
    var seconds=0.0, high=0.0, temperature:Double?
    var apps:[String:Double]=[:], samples:[String:Int]=[:]
}

final class Ledger {
    private var db:OpaquePointer?
    private(set) var totals:[String:Traffic]=[:]
    private var dirtyDays=Set<String>()
    private var pending:[Int64:MinuteRecord]=[:]
    private var lastFlush:TimeInterval = -.infinity
    private var lastPruneDay:String?
    private(set) var error:String?
    static func day(_ date:Date, calendar:Calendar = .current) -> String {
        let c=calendar.dateComponents([.year,.month,.day],from:date)
        return String(format:"%04d-%02d-%02d",c.year!,c.month!,c.day!)
    }
    init(directory:URL?=nil) {
        do {
            let directory=directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nabiz",isDirectory:true)
            try Self.prepareDirectory(directory)
            guard let canonical=realpath(directory.path,nil) else {throw StoreError.failed}
            defer {free(canonical)}
            let path=String(cString:canonical)+"/metrics.sqlite3"
            // Check SQLite sidecars too before SQLite can recover or replace a journal.
            for suffix in ["-journal","-wal","-shm"] {
                let side=open(path+suffix,O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
                if side<0 {guard errno==ENOENT else {throw StoreError.failed};continue}
                defer {close(side)}
                var sideInfo=stat()
                guard fstat(side,&sideInfo)==0,sideInfo.st_mode & S_IFMT == S_IFREG,sideInfo.st_uid==getuid(),sideInfo.st_nlink==1,fchmod(side,0o600)==0 else {throw StoreError.failed}
            }
            let fd=open(path,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0o600)
            guard fd>=0 else {throw StoreError.failed}
            defer {close(fd)}
            var info=stat()
            guard fstat(fd,&info)==0,info.st_mode & S_IFMT == S_IFREG,info.st_uid==getuid(),info.st_nlink==1,info.st_size<=64*1024*1024,fchmod(fd,0o600)==0 else {throw StoreError.failed}
            guard sqlite3_open_v2(path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK else {throw StoreError.failed}
            guard mb_sqlite_harden(db) else {throw StoreError.failed}
            sqlite3_busy_timeout(db,100)
            sqlite3_limit(db,SQLITE_LIMIT_LENGTH,64*1024)
            try execute("PRAGMA trusted_schema=OFF")
            try execute("CREATE TABLE IF NOT EXISTS traffic(day TEXT PRIMARY KEY, received INTEGER NOT NULL, sent INTEGER NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS minutes(time INTEGER PRIMARY KEY, seconds REAL, high REAL, temp REAL, apps TEXT)")
            let statement=try prepare("SELECT day,received,sent FROM traffic ORDER BY day DESC LIMIT 10000")
            defer {sqlite3_finalize(statement)}
            var status=sqlite3_step(statement)
            while status==SQLITE_ROW {
                defer {status=sqlite3_step(statement)}
                guard let raw=sqlite3_column_text(statement,0) else {continue}
                let key=String(cString:raw)
                guard key.utf8.count==10 else {continue}
                totals[key]=Traffic(received:UInt64(max(0,sqlite3_column_int64(statement,1))),sent:UInt64(max(0,sqlite3_column_int64(statement,2))))
            }
            guard status==SQLITE_DONE else {throw StoreError.failed}
        } catch {sqlite3_close(db);db=nil;self.error=L("Yerel kayıt güvenle açılamadı","Local records couldn't be opened safely")}
    }
    static func prepareDirectory(_ directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd=open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else {throw StoreError.failed}
        defer {close(fd)}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_uid==getuid(),fchmod(fd,0o700)==0 else {throw StoreError.failed}
    }
    private enum StoreError:Error {case failed}
    deinit {flush();sqlite3_close(db)}
    private func execute(_ sql:String) throws {
        guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else {throw StoreError.failed}
    }
    private func prepare(_ sql:String) throws -> OpaquePointer {
        guard db != nil else {throw StoreError.failed}
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK,let statement=statement else {throw StoreError.failed}
        return statement
    }
    private func add(_ traffic:Traffic,to day:String) {
        guard traffic.received>0 || traffic.sent>0 else {return}
        var old=totals[day]
        if old==nil,let statement=try? prepare("SELECT received,sent FROM traffic WHERE day=?") {
            defer {sqlite3_finalize(statement)}
            _=day.withCString{sqlite3_bind_text(statement,1,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
            if sqlite3_step(statement)==SQLITE_ROW {old=Traffic(received:UInt64(max(0,sqlite3_column_int64(statement,0))),sent:UInt64(max(0,sqlite3_column_int64(statement,1))))}
        }
        totals[day]=Traffic(received:saturatedSum(old?.received ?? 0,traffic.received),sent:saturatedSum(old?.sent ?? 0,traffic.sent))
        dirtyDays.insert(day)
    }
    func add(_ delta:NetworkDelta, at now:Date, calendar:Calendar = .current) {
        guard delta.seconds>0 else {return}
        let before=now.addingTimeInterval(-delta.seconds),current=Self.day(now,calendar:calendar),prior=Self.day(before,calendar:calendar)
        if current==prior {add(Traffic(received:delta.received,sent:delta.sent),to:current)}
        else {
            let fraction=min(1,max(0,calendar.startOfDay(for:now).timeIntervalSince(before)/delta.seconds))
            let down=finiteCount(Double(delta.received)*fraction),up=finiteCount(Double(delta.sent)*fraction)
            add(Traffic(received:down,sent:up),to:prior)
            add(Traffic(received:delta.received-down,sent:delta.sent-up),to:current)
        }
    }
    func record(at now:Date, elapsed:Double, high:Bool, temperature:Double?, apps:[AppLoad], enabled:Bool) {
        guard enabled,elapsed>0,elapsed<30 else {return}
        let bucket=Int64(now.timeIntervalSince1970)/60*60
        // Bound the backlog during persistent disk errors; never discard uncommitted rows.
        guard pending[bucket] != nil || pending.count<1440 else {error=L("Geçmiş kaydı durdu: yazılmayı bekleyen veriler var","History recording stopped: data is waiting to be written");return}
        var row=pending[bucket] ?? MinuteRecord()
        row.seconds+=elapsed;if high {row.high+=elapsed}
        if let temp=temperature,temp.isFinite,temp>0,temp<130 {row.temperature=max(row.temperature ?? temp,temp)}
        if high {
            for app in apps.prefix(3) where app.cpu.isFinite && app.cpu>=0 {
                let name=safeProcessName(app.name)
                row.apps[name,default:0]+=app.cpu;row.samples[name,default:0]+=1
            }
        }
        pending[bucket]=row
    }
    func flushIfNeeded(uptime:TimeInterval) {if uptime-lastFlush>=60 {flush();lastFlush=uptime}}
    func flush() {
        guard db != nil else {return}
        let pruneDay=Self.day(Date())
        guard !dirtyDays.isEmpty || !pending.isEmpty || lastPruneDay != pruneDay else {return}
        do {
            try execute("BEGIN IMMEDIATE")
            for day in dirtyDays {
                let traffic=totals[day] ?? Traffic()
                let statement=try prepare("INSERT OR REPLACE INTO traffic VALUES(?,?,?)")
                defer {sqlite3_finalize(statement)}
                _=day.withCString{sqlite3_bind_text(statement,1,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
                sqlite3_bind_int64(statement,2,Int64(min(traffic.received,UInt64(Int64.max))))
                sqlite3_bind_int64(statement,3,Int64(min(traffic.sent,UInt64(Int64.max))))
                guard sqlite3_step(statement)==SQLITE_DONE else {throw StoreError.failed}
            }
            for (minute,row) in pending {
                let apps=row.apps.map{AppLoad(name:$0.key,cpu:$0.value/Double(max(1,row.samples[$0.key] ?? 1)))}.sorted{$0.cpu>$1.cpu}.prefix(3)
                let encoded=try JSONEncoder().encode(Array(apps))
                let text=String(decoding:encoded,as:UTF8.self)
                let sql="INSERT INTO minutes VALUES(?,?,?,?,?) ON CONFLICT(time) DO UPDATE SET seconds=minutes.seconds+excluded.seconds,high=minutes.high+excluded.high,temp=CASE WHEN minutes.temp IS NULL THEN excluded.temp WHEN excluded.temp IS NULL THEN minutes.temp ELSE MAX(minutes.temp,excluded.temp) END,apps=CASE WHEN excluded.apps='[]' THEN minutes.apps ELSE excluded.apps END"
                let statement=try prepare(sql)
                defer {sqlite3_finalize(statement)}
                sqlite3_bind_int64(statement,1,minute);sqlite3_bind_double(statement,2,row.seconds);sqlite3_bind_double(statement,3,row.high)
                if let temp=row.temperature {sqlite3_bind_double(statement,4,temp)} else {sqlite3_bind_null(statement,4)}
                _=text.withCString{sqlite3_bind_text(statement,5,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
                guard sqlite3_step(statement)==SQLITE_DONE else {throw StoreError.failed}
            }
            if lastPruneDay != pruneDay {try execute("DELETE FROM minutes WHERE time < \(Int64(Date().timeIntervalSince1970)-14*86400)")}
            try execute("COMMIT")
            dirtyDays.removeAll(keepingCapacity:true);pending.removeAll(keepingCapacity:true);lastPruneDay=pruneDay;error=nil
        } catch {
            try? execute("ROLLBACK")
            self.error=L("Yerel kayıt yazılamadı; veriler yeniden denenecek","Couldn't write local records; will retry")
        }
    }
    func summary(days:Int, at now:Date=Date()) -> HistorySummary {
        flush()
        let calendar=Calendar.current
        let start=calendar.date(byAdding:.day,value:-(min(14,max(1,days))-1),to:calendar.startOfDay(for:now))!
        let dayCount=min(14,max(1,days))
        var result=HistorySummary(),loads:[String:(Double,Int)]=[:],hours:[Date:Double]=[:]
        result.storageError=error;result.hourly=dayCount==1
        if result.hourly {
            result.buckets=(0..<24).map{HistoryBucket(start:calendar.date(byAdding:.hour,value:$0,to:start) ?? start.addingTimeInterval(Double($0)*3600))}
        } else {
            result.buckets=(0..<dayCount).map{
                let day=calendar.date(byAdding:.day,value:$0,to:start)!
                return HistoryBucket(start:day,traffic:totals[Self.day(day,calendar:calendar)] ?? Traffic())
            }
        }
        for offset in 0..<dayCount {
            let day=calendar.date(byAdding:.day,value:offset,to:start)!
            if let t=totals[Self.day(day,calendar:calendar)] {result.traffic=Traffic(received:saturatedSum(result.traffic.received,t.received),sent:saturatedSum(result.traffic.sent,t.sent))}
        }
        func bucketIndex(_ stamp:Date)->Int? {
            let index=result.hourly ? calendar.component(.hour,from:stamp) : (calendar.dateComponents([.day],from:start,to:calendar.startOfDay(for:stamp)).day ?? -1)
            return result.buckets.indices.contains(index) ? index:nil
        }
        do {
            let statement=try prepare("SELECT seconds,high,temp,apps,time FROM minutes WHERE time>=? AND time<=? ORDER BY time LIMIT 20161")
            defer {sqlite3_finalize(statement)}
            sqlite3_bind_int64(statement,1,Int64(start.timeIntervalSince1970));sqlite3_bind_int64(statement,2,Int64(now.timeIntervalSince1970))
            var status=sqlite3_step(statement)
            while status==SQLITE_ROW {
                defer {status=sqlite3_step(statement)}
                let seconds=sqlite3_column_double(statement,0),high=sqlite3_column_double(statement,1)
                guard seconds.isFinite,high.isFinite,seconds>=0,seconds<=90,high>=0,high<=seconds else {continue}
                result.seconds+=seconds;result.highSeconds+=high;result.minutes+=1
                let stamp=Date(timeIntervalSince1970:Double(sqlite3_column_int64(statement,4)))
                let index=bucketIndex(stamp)
                if let index {result.buckets[index].seconds+=seconds;result.buckets[index].high+=high}
                if high>0 {
                    if let hour=calendar.dateInterval(of:.hour,for:stamp)?.start {hours[hour,default:0]+=high}
                }
                if sqlite3_column_type(statement,2) != SQLITE_NULL {
                    let t=sqlite3_column_double(statement,2)
                    if t.isFinite,t>0,t<130 {
                        result.maxTemp=max(result.maxTemp ?? t,t)
                        if let index {result.buckets[index].maxTemp=max(result.buckets[index].maxTemp ?? t,t)}
                    }
                }
                if sqlite3_column_bytes(statement,3)<=4096,let text=sqlite3_column_text(statement,3),let apps=try? JSONDecoder().decode([AppLoad].self,from:Data(String(cString:text).utf8)) {
                    for app in apps.prefix(3) where app.cpu.isFinite && app.cpu>=0 {
                        let name=safeProcessName(app.name),old=loads[name] ?? (0,0);loads[name]=(old.0+app.cpu,old.1+1)
                    }
                }
            }
            guard status==SQLITE_DONE else {throw StoreError.failed}
        } catch {result.storageError=self.error ?? L("Geçmiş okunamadı","Couldn't read history")}
        if let peak=hours.max(by:{$0.value<$1.value}) {
            let f=DateFormatter();f.locale=appLocale;f.dateFormat="d MMM HH:mm"
            let end=DateFormatter();end.dateFormat="HH:mm"
            let duration=peak.value<60 ? "\(Int(peak.value)) "+L("sn","s") : "\(Int(peak.value/60)) "+L("dk","min")
            result.busiest="\(f.string(from:peak.key))–\(end.string(from:peak.key.addingTimeInterval(3600))) · \(duration)"
        }
        result.applications=loads.map{AppLoad(name:$0.key,cpu:$0.value.0/Double($0.value.1))}.sorted{$0.cpu>$1.cpu}.prefix(5).map{$0}
        return result
    }
}
