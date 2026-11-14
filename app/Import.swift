import AppKit
import CryptoKit
import SQLite3
import Darwin

struct ImportReceipt { let digest:String;let backup:URL }
enum ImportFailure:LocalizedError {
    case unsafeSource,invalidDatabase,destinationExists,cancelled,sourceChanged,sourceBusy,importUnavailable
    var errorDescription:String? {
        switch self {
        case .importUnavailable:return "Kayıt aktarımı yalnız ayrı geçiş derlemesinde açık."
        case .unsafeSource:return "Kaynak dosya güvenle okunamadı."
        case .invalidDatabase:return "Dosya doğrulanmış bir Nabız veritabanı değil."
        case .destinationExists:return "Korumalı alanda zaten kayıt var; üzerine yazılmadı."
        case .cancelled:return "Taşıma iptal edildi."
        case .sourceBusy:return "Önce çalışan Nabız oturumundan çıkın."
        case .sourceChanged:return "Kaynak dosya değişti; eski kopya kaldırılmadı."
        }
    }
}
private func snapshot(_ source:URL) throws -> Data {
    let fd=open(source.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
    guard fd>=0 else {throw ImportFailure.unsafeSource}
    let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
    var info=stat()
    guard fstat(fd,&info)==0,info.st_mode & S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_nlink==1,info.st_size>0,info.st_size<=64*1024*1024 else {throw ImportFailure.unsafeSource}
    var data=Data()
    while let chunk=try handle.read(upToCount:65536),!chunk.isEmpty {
        data.append(chunk)
        guard data.count<=64*1024*1024 else {throw ImportFailure.unsafeSource}
    }
    return data
}
private func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}

// Local byte-for-byte copy, not a schema migration. Never overwrites current data.
func copyLegacyRecords(source:URL,directory:URL) throws -> ImportReceipt {
    let destination=directory.appendingPathComponent("metrics.sqlite3")
    guard !FileManager.default.fileExists(atPath:destination.path) else {throw ImportFailure.destinationExists}
    let data=try snapshot(source)
    try Ledger.prepareDirectory(directory)
    let stage=directory.appendingPathComponent(".import-"+UUID().uuidString)
    try data.write(to:stage,options:.atomic)
    defer {try? FileManager.default.removeItem(at:stage)}
    guard chmod(stage.path,0o600)==0 else {throw ImportFailure.unsafeSource}
    guard let raw=realpath(stage.path,nil) else {throw ImportFailure.invalidDatabase}
    defer {free(raw)}
    var db:OpaquePointer?
    defer {sqlite3_close(db)}
    guard sqlite3_open_v2(raw,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_NOFOLLOW,nil)==SQLITE_OK,mb_sqlite_harden(db) else {throw ImportFailure.invalidDatabase}
    sqlite3_limit(db,SQLITE_LIMIT_LENGTH,64*1024)
    func valid(_ sql:String,expected:String)->Bool {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&statement,nil)==SQLITE_OK else {return false}
        defer {sqlite3_finalize(statement)}
        guard sqlite3_step(statement)==SQLITE_ROW,let value=sqlite3_column_text(statement,0) else {return false}
        return String(cString:value)==expected
    }
    guard valid("PRAGMA quick_check",expected:"ok"),valid("SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('traffic','minutes')",expected:"2") else {throw ImportFailure.invalidDatabase}
    for sql in ["SELECT day,received,sent FROM traffic LIMIT 0","SELECT time,seconds,high,temp,apps FROM minutes LIMIT 0"] {
        var statement:OpaquePointer?
        let rc=sqlite3_prepare_v2(db,sql,-1,&statement,nil);sqlite3_finalize(statement)
        guard rc==SQLITE_OK else {throw ImportFailure.invalidDatabase}
    }
    let backupDirectory=directory.appendingPathComponent("Backups")
    try Ledger.prepareDirectory(backupDirectory)
    let backup=backupDirectory.appendingPathComponent("pre-sandbox-"+UUID().uuidString+".sqlite3")
    try data.write(to:backup,options:.atomic)
    guard chmod(backup.path,0o600)==0 else {throw ImportFailure.unsafeSource}
    // moveItem refuses an existing destination, including a race with another launch.
    try FileManager.default.moveItem(at:stage,to:destination)
    let hash=digest(data)
    guard digest(try snapshot(destination))==hash,digest(try snapshot(backup))==hash else {throw ImportFailure.invalidDatabase}
    return ImportReceipt(digest:hash,backup:backup)
}

func importLegacyRecordsInteractively() throws {
#if NABIZ_MIGRATION_BUILD
    let app=NSApplication.shared;app.setActivationPolicy(.accessory);app.activate(ignoringOtherApps:true)
    guard !NSRunningApplication.runningApplications(withBundleIdentifier:"local.nabiz.monitor").contains(where:{$0.processIdentifier != getpid()}) else {throw ImportFailure.sourceBusy}
    guard let realHome=getpwuid(getuid())?.pointee.pw_dir else {throw ImportFailure.unsafeSource}
    let legacy=URL(fileURLWithPath:String(cString:realHome)).appendingPathComponent("Library/Application Support/Nabiz/metrics.sqlite3")
    let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nabiz")
    guard !FileManager.default.fileExists(atPath:directory.appendingPathComponent("metrics.sqlite3").path) else {throw ImportFailure.destinationExists}
    let panel=NSOpenPanel();panel.title="Nabız kayıtlarını korumalı alana taşı";panel.message="Eski metrics.sqlite3 dosyasını seçin. Doğrulanmış yedeği korumalı alanda tutulacak.";panel.prompt="Seç"
    panel.directoryURL=legacy.deletingLastPathComponent();panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
    app.finishLaunching()
    let host=NSWindow(contentRect:NSRect(x:0,y:0,width:460,height:180),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    host.title="Nabız · Korumalı alana geçiş";host.isReleasedWhenClosed=false
    let note=NSTextField(wrappingLabelWithString:"Mevcut Nabız kayıtlarını seçin. Kayıtlarınız ve doğrulanmış yedeği özel kapsayıcıda korunacak.")
    note.frame=NSRect(x:24,y:56,width:412,height:72);host.contentView?.addSubview(note)
    host.center();host.makeKeyAndOrderFront(nil)
    var choice:NSApplication.ModalResponse = .cancel
    panel.beginSheetModal(for:host){response in choice=response;app.stopModal()}
    app.runModal(for:host)
    host.close()
    guard choice == .OK,let source=panel.url,source.standardizedFileURL==legacy.standardizedFileURL else {throw ImportFailure.cancelled}
    let access=source.startAccessingSecurityScopedResource();defer {if access {source.stopAccessingSecurityScopedResource()}}
    let alert=NSAlert();alert.messageText="Nabız kayıtları taşınsın mı?";alert.informativeText="Kayıtlar özel kapsayıcıya kopyalanıp doğrulanacak. Aynı alanda ayrıca yedek tutulacak. Ardından eski konumdaki kopya kaldırılacak. Nabız’ın önceki sürümünden çıkılmış olmalı."
    alert.addButton(withTitle:"Taşı ve koru");alert.addButton(withTitle:"Vazgeç")
    guard alert.runModal() == .alertFirstButtonReturn else {throw ImportFailure.cancelled}
    let receipt=try copyLegacyRecords(source:source,directory:directory)
    guard digest(try snapshot(source))==receipt.digest else {throw ImportFailure.sourceChanged}
    try FileManager.default.removeItem(at:source)
    print("PASS: records and protected backup verified; legacy copy retired")
#else
    throw ImportFailure.importUnavailable
#endif
}
