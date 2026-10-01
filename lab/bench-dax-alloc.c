// bench-dax-alloc: what it costs to make a 4K frame buffer on WSLg's DAX share (/mnt/wslgshm) ready
// for writing, per strategy, and what the first full-frame write costs afterwards.
// build: cc -O2 bench-dax-alloc.c -o bench-dax-alloc
// run:   ./bench-dax-alloc [DIR]          strategies, one buffer at a time
//        ./bench-dax-alloc DIR N [P [A]]  N buffers kept mapped at once; P: 0 lazy, 1 populate+memset,
//                                         2 memset, 3 MADV_POPULATE_WRITE; A: 1 = 2 MiB-aligned
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifndef MADV_POPULATE_WRITE
#define MADV_POPULATE_WRITE 23
#endif

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

enum { PLAIN = 0, ALIGN2M = 1 };
enum { NONE, POPULATE_MEMSET, MEMSET, MADV_WRITE };
static const char* PREP[] = {"lazy (no prefault)", "MAP_POPULATE + memset", "memset", "MADV_POPULATE_WRITE"};

static void run(const char* dir, int prep, int align) {
    const size_t SZ = 3840UL * 2160 * 4, M2 = 2UL << 20;
    char path[256];
    snprintf(path, sizeof(path), "%s/bench-dax-%d-%d-%d", dir, getpid(), prep, align);
    int fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0 || fallocate(fd, 0, 0, SZ) != 0) {
        perror(path);
        exit(1);
    }
    unlink(path);  // DAX files go away on last close anyway; don't leave one behind on a crash

    double t0 = now_ms();
    void*  hint = NULL;
    if (align == ALIGN2M) {  // reserve, then place the file mapping on a 2 MiB boundary
        uint8_t* r = mmap(NULL, SZ + M2, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        hint       = (void*)(((uintptr_t)r + M2 - 1) & ~(M2 - 1));
    }
    int      flags = MAP_SHARED | (hint ? MAP_FIXED : 0) | (prep == POPULATE_MEMSET ? MAP_POPULATE : 0);
    uint8_t* p     = mmap(hint, SZ, PROT_READ | PROT_WRITE, flags, fd, 0);
    if (p == MAP_FAILED) {
        perror("mmap");
        exit(1);
    }
    double t1 = now_ms();
    if (prep == POPULATE_MEMSET || prep == MEMSET)
        memset(p, 0, SZ);
    else if (prep == MADV_WRITE && madvise(p, SZ, MADV_POPULATE_WRITE) != 0)
        perror("madvise");
    double t2 = now_ms();
    memset(p, 0x55, SZ);  // the first frame
    double t3 = now_ms();
    memset(p, 0xaa, SZ);  // steady state
    double t4 = now_ms();
    printf("%-24s %-8s map %7.1f ms  prepare %7.1f ms  first frame %7.1f ms  next frame %5.1f ms\n", PREP[prep],
           align ? "2M-align" : "plain", t1 - t0, t2 - t1, t3 - t2, t4 - t3);
    munmap(p, SZ);
    close(fd);
}

// Keep N 4K buffers mapped at once (like 3 outputs x 3 swapchain buffers) and time each one's
// preparation: a cost that grows with N means the DAX window is full and mappings get recycled.
static void many(const char* dir, int n, int prep, int align) {
    const size_t SZ = 3840UL * 2160 * 4, M2 = 2UL << 20;
    double       total = 0;
    printf("%d buffers, %s, %s\n", n, PREP[prep], align ? "2M-align" : "plain");
    for (int i = 0; i < n; i++) {
        char path[256];
        snprintf(path, sizeof(path), "%s/bench-dax-many-%d-%d", dir, getpid(), i);
        int fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd < 0 || fallocate(fd, 0, 0, SZ) != 0) {
            perror(path);
            exit(1);
        }
        unlink(path);
        double t0   = now_ms();
        void*  hint = NULL;
        if (align == ALIGN2M) {
            uint8_t* r = mmap(NULL, SZ + M2, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
            hint       = (void*)(((uintptr_t)r + M2 - 1) & ~(M2 - 1));
        }
        int      flags = MAP_SHARED | (hint ? MAP_FIXED : 0) | (prep == POPULATE_MEMSET ? MAP_POPULATE : 0);
        uint8_t* p     = mmap(hint, SZ, PROT_READ | PROT_WRITE, flags, fd, 0);
        if (p == MAP_FAILED) {
            perror("mmap");
            exit(1);
        }
        if (prep == POPULATE_MEMSET || prep == MEMSET)
            memset(p, 0, SZ);
        else if (prep == MADV_WRITE && madvise(p, SZ, MADV_POPULATE_WRITE) != 0)
            perror("madvise");
        double t1 = now_ms();
        memset(p, 0x55, SZ);
        double t2 = now_ms();
        total += t2 - t0;
        printf("  buffer %2d: prepare %7.1f ms  first write %7.1f ms  (%d MiB mapped)\n", i, t1 - t0, t2 - t1, (int)((i + 1) * SZ >> 20));
        // leaked on purpose: every buffer stays mapped until exit
    }
    printf("  total %.0f ms\n", total);
}

int main(int argc, char** argv) {
    const char* dir = argc > 1 ? argv[1] : "/mnt/wslgshm";
    if (argc > 2) {  // N [PREP 0-3] [ALIGN 0-1]
        many(dir, atoi(argv[2]), argc > 3 ? atoi(argv[3]) : MEMSET, argc > 4 ? atoi(argv[4]) : PLAIN);
        return 0;
    }
    for (int align = PLAIN; align <= ALIGN2M; align++)
        for (int prep = NONE; prep <= MADV_WRITE; prep++)
            run(dir, prep, align);
    return 0;
}
