#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <sched.h>
#include <unistd.h>

extern uint64_t _minimal_rename(void);
extern uint64_t _extra_rename(void);

extern uint64_t _minimal_rename_avx2(void);
extern uint64_t _extra_rename_avx2(void);

int main(void) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(0, &set);
    sched_setaffinity(0, sizeof(set), &set);

    uint64_t base  = _minimal_rename_avx2();
    // uint64_t extra = _extra_rename_avx2();

    return 0;
}
