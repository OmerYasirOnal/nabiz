#include "Metrics.h"
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

bool mb_sqlite_harden(sqlite3 *db) {
    return sqlite3_db_config(db,SQLITE_DBCONFIG_DEFENSIVE,1,NULL)==SQLITE_OK &&
        sqlite3_db_config(db,SQLITE_DBCONFIG_TRUSTED_SCHEMA,0,NULL)==SQLITE_OK &&
        sqlite3_db_config(db,SQLITE_DBCONFIG_ENABLE_TRIGGER,0,NULL)==SQLITE_OK;
}

MBHost mb_host_read(void) {
    MBHost result = {0};
    host_cpu_load_info_data_t cpu = {0};
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host = mach_host_self();
    if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &count) == KERN_SUCCESS) {
        result.user_ticks=cpu.cpu_ticks[CPU_STATE_USER]; result.system_ticks=cpu.cpu_ticks[CPU_STATE_SYSTEM];
        result.idle_ticks=cpu.cpu_ticks[CPU_STATE_IDLE]; result.nice_ticks=cpu.cpu_ticks[CPU_STATE_NICE];
        result.cpu_valid=true;
    }
    vm_statistics64_data_t vm = {0}; count = HOST_VM_INFO64_COUNT;
    vm_size_t page_size=0; host_page_size(host,&page_size);
    size_t size=sizeof(result.ram_total);
    sysctlbyname("hw.memsize",&result.ram_total,&size,NULL,0);
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count)==KERN_SUCCESS) {
        uint64_t internal=vm.internal_page_count>vm.purgeable_count ? vm.internal_page_count-vm.purgeable_count : 0;
        result.ram_used=(internal+vm.wire_count+vm.compressor_page_count)*page_size;
        if(result.ram_used>result.ram_total) result.ram_used=result.ram_total;
        result.ram_compressed=(uint64_t)vm.compressor_page_count*page_size;
        result.memory_valid=true;
    }
    mach_port_deallocate(mach_task_self(),host);
    struct xsw_usage swap={0}; size=sizeof(swap);
    if(sysctlbyname("vm.swapusage",&swap,&size,NULL,0)==0) result.swap_used=swap.xsu_used;
    size=sizeof(result.pressure);
    if(sysctlbyname("kern.memorystatus_vm_pressure_level",&result.pressure,&size,NULL,0)!=0) result.pressure=0;
    return result;
}

// C layout is intentional: the AppleSMC read ABI is 80 bytes. Only key-info (9)
// and read-bytes (5) commands are implemented. There is no fan-control/write path.
// Protocol references: beltex/SMCKit and exelban/stats (see KULLANIM.md).
typedef struct {uint8_t major,minor,build,reserved;uint16_t release;} SMCVersion;
typedef struct {uint16_t version,length;uint32_t cpu,gpu,memory;} SMCLimits;
typedef struct {uint32_t size,type;uint8_t attributes;} SMCInfo;
typedef struct {
    uint32_t key; SMCVersion version; SMCLimits limits; SMCInfo info;
    uint8_t result,status,command; uint32_t data; uint8_t bytes[32];
} SMCMessage;
_Static_assert(sizeof(SMCMessage)==80,"SMC ABI size mismatch");
static uint32_t fourcc(const char *text) {
    return ((uint32_t)(uint8_t)text[0]<<24)|((uint32_t)(uint8_t)text[1]<<16)|((uint32_t)(uint8_t)text[2]<<8)|(uint8_t)text[3];
}
uint32_t mb_smc_open(void) {
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
    if(!service) return 0;
    io_connect_t connection=0;
    kern_return_t status=IOServiceOpen(service,mach_task_self(),0,&connection);
    IOObjectRelease(service);
    return status==KERN_SUCCESS ? connection : 0;
}
void mb_smc_close(uint32_t connection) {if(connection) IOServiceClose(connection);}
bool mb_smc_read(uint32_t connection,const char *key,double *value) {
    if(!connection || !key || strlen(key)!=4 || !value) return false;
    SMCMessage input={0},output={0};size_t size=sizeof(output);
    input.key=fourcc(key);input.command=9;
    if(IOConnectCallStructMethod(connection,2,&input,sizeof(input),&output,&size)!=KERN_SUCCESS || size!=sizeof(output) || output.result || output.info.size==0 || output.info.size>32) return false;
    uint32_t type=output.info.type, length=output.info.size;
    input.info.size=length;input.command=5;memset(&output,0,sizeof(output));size=sizeof(output);
    if(IOConnectCallStructMethod(connection,2,&input,sizeof(input),&output,&size)!=KERN_SUCCESS || size!=sizeof(output) || output.result) return false;
    double number=0;
    if(type==fourcc("flt ") && length==4) {float f=0;memcpy(&f,output.bytes,4);number=f;}
    else if(type==fourcc("fpe2") && length==2) number=((output.bytes[0]<<8)|output.bytes[1])/4.0;
    else if(type==fourcc("sp78") && length==2) number=(int16_t)((output.bytes[0]<<8)|output.bytes[1])/256.0;
    else if(type==fourcc("ui8 ") && length==1) number=output.bytes[0];
    else if(type==fourcc("ui16") && length==2) number=(output.bytes[0]<<8)|output.bytes[1];
    else if(type==fourcc("ui32") && length==4) number=fourcc((char *)output.bytes);
    else return false;
    if(!isfinite(number)) return false;
    *value=number;return true;
}
double mb_gpu_read(void) {
    io_iterator_t iterator=0; double value=-1;
    if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOAccelerator"),&iterator)!=KERN_SUCCESS) return value;
    io_service_t service=0;
    while((service=IOIteratorNext(iterator))) {
        CFTypeRef raw=IORegistryEntryCreateCFProperty(service,CFSTR("PerformanceStatistics"),kCFAllocatorDefault,0);
        if(raw && CFGetTypeID(raw)==CFDictionaryGetTypeID()) {
            CFTypeRef number=CFDictionaryGetValue(raw,CFSTR("Device Utilization %"));
            double candidate=-1;
            if(number && CFGetTypeID(number)==CFNumberGetTypeID()) CFNumberGetValue(number,kCFNumberDoubleType,&candidate);
            if(candidate>=0 && candidate<=100) value=fmax(value,candidate);
        }
        if(raw) CFRelease(raw);IOObjectRelease(service);
    }
    IOObjectRelease(iterator);return value;
}

uint64_t mb_own_footprint(void) {
    task_vm_info_data_t info={0};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&count)==KERN_SUCCESS ? info.phys_footprint : 0;
}
double mb_own_cpu_seconds(void) {
    struct rusage usage={0};getrusage(RUSAGE_SELF,&usage);
    return usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6;
}

// 64-bit counters, individually keyed by interface. Avoid VPN/bridge double counting.
int mb_interfaces(MBInterface *entries,int capacity) {
    int mib[]={CTL_NET,PF_ROUTE,0,AF_LINK,NET_RT_IFLIST2,0};size_t length=0;
    if(sysctl(mib,6,NULL,&length,NULL,0)!=0 || length>16*1024*1024) return -1;
    char *buffer=malloc(length);if(!buffer)return -1;
    if(sysctl(mib,6,buffer,&length,NULL,0)!=0){free(buffer);return -1;}
    int count=0;
    for(char *cursor=buffer;cursor+4<=buffer+length;){
        struct if_msghdr *header=(struct if_msghdr *)cursor;
        if(header->ifm_msglen<4 || cursor+header->ifm_msglen>buffer+length)break;
        if(header->ifm_type==RTM_IFINFO2 && header->ifm_msglen>=sizeof(struct if_msghdr2)){
            struct if_msghdr2 *item=(struct if_msghdr2 *)cursor;char name[IFNAMSIZ]={0};
            if(if_indextoname(item->ifm_index,name) && strncmp(name,"en",2)==0 && (item->ifm_flags&IFF_UP) && count<capacity){
                MBInterface *out=&entries[count++];memset(out,0,sizeof(*out));strncpy(out->name,name,sizeof(out->name)-1);
                out->index=item->ifm_index;out->received=item->ifm_data.ifi_ibytes;out->sent=item->ifm_data.ifi_obytes;
            }
        }
        cursor+=header->ifm_msglen;
    }
    free(buffer);return count;
}
int mb_processes(MBProcess *entries,int capacity) {
    mach_timebase_info_data_t timebase={0};
    if(mach_timebase_info(&timebase)!=KERN_SUCCESS || !timebase.denom)return -1;
    // These read-only APIs are allowed by App Sandbox without process exceptions.
    int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0};size_t length=0;
    if(sysctl(mib,4,NULL,&length,NULL,0)!=0 || !length || length>16*1024*1024)return -1;
    struct kinfo_proc *processes=malloc(length);if(!processes)return -1;
    if(sysctl(mib,4,processes,&length,NULL,0)!=0){free(processes);return -1;}
    int count=0;
    for(size_t i=0;i<length/sizeof(*processes) && count<capacity;i++){
        pid_t pid=processes[i].kp_proc.p_pid;
        struct proc_taskallinfo info={0};
        if(pid<=0 || proc_pidinfo(pid,PROC_PIDTASKALLINFO,0,&info,sizeof(info))!=sizeof(info))continue;
        MBProcess *out=&entries[count];memset(out,0,sizeof(*out));
        const char *name=info.pbsd.pbi_name[0] ? info.pbsd.pbi_name:info.pbsd.pbi_comm;
        size_t limit=info.pbsd.pbi_name[0] ? sizeof(info.pbsd.pbi_name):sizeof(info.pbsd.pbi_comm);
        memcpy(out->name,name,strnlen(name,limit));out->name[sizeof(out->name)-1]='\0';
        __uint128_t ns=((__uint128_t)info.ptinfo.pti_total_user+info.ptinfo.pti_total_system)*timebase.numer/timebase.denom;
        out->pid=pid;out->cpu_ns=ns>UINT64_MAX ? UINT64_MAX:(uint64_t)ns;
        out->start=info.pbsd.pbi_start_tvsec*1000000+info.pbsd.pbi_start_tvusec;
        count++;
    }
    free(processes);return count;
}
