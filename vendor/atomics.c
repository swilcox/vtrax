// Minimal atomic primitives over GCC/Clang __atomic builtins. These back the
// lock-free state shared between the miniaudio callback (a non-V thread) and
// the UI thread, and the SPSC ring indices. Keeping them here (rather than
// leaning on V's sync.stdatomic internals) gives explicit, portable control of
// memory ordering and is safe to call from the real-time audio thread.
#include <stdint.h>

// Relaxed (== ztrax's .monotonic): used for the published shared state, where
// each value is independent and only single-writer / single-reader.
uint32_t vtx_load_u32(void *p) {
  return __atomic_load_n((uint32_t *)p, __ATOMIC_RELAXED);
}
void vtx_store_u32(void *p, uint32_t v) {
  __atomic_store_n((uint32_t *)p, v, __ATOMIC_RELAXED);
}
uint64_t vtx_load_u64(void *p) {
  return __atomic_load_n((uint64_t *)p, __ATOMIC_RELAXED);
}
void vtx_store_u64(void *p, uint64_t v) {
  __atomic_store_n((uint64_t *)p, v, __ATOMIC_RELAXED);
}
uint64_t vtx_add_u64(void *p, uint64_t d) {
  return __atomic_add_fetch((uint64_t *)p, d, __ATOMIC_RELAXED);
}
uint32_t vtx_swap_u32(void *p, uint32_t v) {
  return __atomic_exchange_n((uint32_t *)p, v, __ATOMIC_RELAXED);
}

// Acquire / release: the SPSC ring's producer publishes the slot with a release
// store to `tail`; the consumer observes it with an acquire load (and mirror
// for `head`), giving the standard happens-before for the buffered item.
uint64_t vtx_load_u64_acq(void *p) {
  return __atomic_load_n((uint64_t *)p, __ATOMIC_ACQUIRE);
}
void vtx_store_u64_rel(void *p, uint64_t v) {
  __atomic_store_n((uint64_t *)p, v, __ATOMIC_RELEASE);
}
