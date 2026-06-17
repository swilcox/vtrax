// Prototypes for the vendored C glue (vendor/ma.c, vendor/atomics.c) so the
// V-generated translation unit sees declarations before use.
#ifndef VTRAX_H
#define VTRAX_H

#include <stdint.h>

// --- miniaudio device glue (ma.c) -------------------------------------------
void *vtrax_device_create(void *userdata, unsigned int *out_rate);
void vtrax_device_destroy(void *dev);

// --- atomics (atomics.c) ----------------------------------------------------
uint32_t vtx_load_u32(void *p);
void vtx_store_u32(void *p, uint32_t v);
uint64_t vtx_load_u64(void *p);
void vtx_store_u64(void *p, uint64_t v);
uint64_t vtx_add_u64(void *p, uint64_t d);
uint32_t vtx_swap_u32(void *p, uint32_t v);
uint64_t vtx_load_u64_acq(void *p);
void vtx_store_u64_rel(void *p, uint64_t v);

#endif
