/* host test of sweet_gpu.c's GPU VA allocator:
 *   awk '/^gpu_va_take\(/{f=1; print "static bool"} f{print} f&&/^}/{exit}' sweet_gpu.c > take.inc
 *   sed -n '/BEGIN va give/,/END va give/p' sweet_gpu.c > give.inc */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define GPU_VA_BYTES   0x40000000ull
#define GPU_VA_EXTENTS 512u
#define GPU_VA_BASE    0x80020000ull
struct gpu_va_extent { uint64_t off, size; };
static struct gpu_va_extent gpu_va_free[GPU_VA_EXTENTS];
#include "take.inc"
#include "give.inc"
#define N 300
static uint64_t off[N], sz[N]; static bool live[N];
static uint64_t free_total(void) { uint64_t t = 0; for (unsigned i = 0; i < GPU_VA_EXTENTS; i++) t += gpu_va_free[i].size; return t; }
int main(void) {
	gpu_va_free[0].off = 0; gpu_va_free[0].size = GPU_VA_BYTES;
	srand(2);
	static const uint64_t sizes[] = { 16384, 163840, 458752, 4194304, 13893632 };
	for (int step = 0; step < 300000; step++) {
		int i = rand() % N;
		if (live[i]) { gpu_va_give(off[i], sz[i]); live[i] = false; }
		else {
			sz[i] = sizes[rand() % 5];
			uint64_t used = 0; for (int k = 0; k < N; k++) if (live[k]) used += sz[k] + 0x1000;
			if (used + sz[i] > (600ull << 20)) continue;
			live[i] = gpu_va_take(sz[i], &off[i]);
			assert(live[i]);                      /* 600 MiB live of a 1 GiB range must always fit */
		}
		for (int a = 0; a < N; a++) if (live[a]) {   /* no overlap, guard pages included */
			assert(off[a] + sz[a] + 0x1000 <= GPU_VA_BYTES);
			for (int b = a + 1; b < N; b++) if (live[b])
				assert(off[a] + sz[a] + 0x1000 <= off[b] || off[b] + sz[b] + 0x1000 <= off[a]);
		}
	}
	for (int i = 0; i < N; i++) if (live[i]) gpu_va_give(off[i], sz[i]);
	assert(free_total() == GPU_VA_BYTES);
	int ext = 0; for (unsigned i = 0; i < GPU_VA_EXTENTS; i++) ext += gpu_va_free[i].size != 0;
	assert(ext == 1);                               /* everything merged back into one range */
	puts("gpu va allocator: all checks passed");
	return 0;
}
