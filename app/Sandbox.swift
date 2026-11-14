import Foundation
import Darwin

// Explicit developer test: harmless fixture outside the container; no data is read or sent.
func runSandboxChecks(outsidePath:String) throws {
    let deniedCodes:[Int32]=[EPERM,EACCES]
    func fileDenied(_ flags:Int32)->Bool {
        let fd=open(outsidePath,flags|O_NOFOLLOW|O_CLOEXEC)
        let code=errno
        if fd>=0 {close(fd);return false}
        return deniedCodes.contains(code)
    }
    func networkDenied(server:Bool)->Bool {
        let fd=socket(AF_INET,SOCK_STREAM,0)
        if fd<0 {return deniedCodes.contains(errno)}
        defer {close(fd)}
        var address=sockaddr_in()
        address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET)
        address.sin_addr.s_addr=inet_addr("127.0.0.1");address.sin_port=server ? 0:UInt16(9).bigEndian
        let result=withUnsafePointer(to:&address){pointer in
            pointer.withMemoryRebound(to:sockaddr.self,capacity:1){target in
                server ? bind(fd,target,socklen_t(MemoryLayout<sockaddr_in>.size)):connect(fd,target,socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result<0 {return deniedCodes.contains(errno)}
        if server {let result=listen(fd,1);return result<0 && deniedCodes.contains(errno)}
        return false
    }
    let home=FileManager.default.homeDirectoryForCurrentUser
    precondition(home.path.contains("/Library/Containers/") && home.lastPathComponent=="Data","Not running in a container")
    let fixture=home.appendingPathComponent("Library/Application Support/Nabiz/sandbox-test-"+UUID().uuidString)
    let ledger=Ledger(directory:fixture)
    defer {try? FileManager.default.removeItem(at:fixture)}
    precondition(ledger.error==nil,"Container storage failed")
    ledger.add(NetworkDelta(received:123,sent:7,seconds:3),at:Date());ledger.flush()
    precondition(ledger.error==nil && Ledger(directory:fixture).totals[Ledger.day(Date())]?.received==123)
    precondition(fileDenied(O_RDONLY),"Outside read was not denied")
    precondition(fileDenied(O_WRONLY),"Outside write was not denied")
    precondition(networkDenied(server:false),"Outbound connection was not denied")
    precondition(networkDenied(server:true),"Listening socket was not denied")
    var processes=Array(repeating:MBProcess(),count:2048)
    let count=processes.withUnsafeMutableBufferPointer{mb_processes($0.baseAddress,Int32($0.count))}
    precondition(count>1 && processes.prefix(Int(count)).contains{$0.pid != getpid()},"System process metrics unavailable")
    print("PASS: private container storage, outside read/write denied, loopback connect/listen denied, system process metrics preserved")
}
