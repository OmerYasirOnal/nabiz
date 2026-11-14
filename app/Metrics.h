#ifndef MINI_METRICS_H
#define MINI_METRICS_H
#include <stdint.h>
#include <stdbool.h>
#include <sqlite3.h>
bool mb_sqlite_harden(sqlite3 *db);
typedef struct {
    uint64_t user_ticks, system_ticks, idle_ticks, nice_ticks;
    uint64_t ram_total, ram_used, ram_compressed, swap_used;
    uint64_t bytes_in, bytes_out;
    int pressure;
    bool cpu_valid, memory_valid;
} MBHost;
MBHost mb_host_read(void);
typedef struct { char name[16]; uint32_t index; uint64_t received, sent; } MBInterface;
int mb_interfaces(MBInterface *entries, int capacity);
typedef struct { int32_t pid; uint64_t cpu_ns, start; char name[64]; } MBProcess;
int mb_processes(MBProcess *entries, int capacity);
uint32_t mb_smc_open(void);
void mb_smc_close(uint32_t connection);
bool mb_smc_read(uint32_t connection, const char *key, double *value);
double mb_gpu_read(void);
uint64_t mb_own_footprint(void);
double mb_own_cpu_seconds(void);
#endif
