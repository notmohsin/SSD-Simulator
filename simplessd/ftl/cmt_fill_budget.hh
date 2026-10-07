#ifndef __FTL_CMT_FILL_BUDGET__
#define __FTL_CMT_FILL_BUDGET__

#include <algorithm>
#include <cstdint>

namespace SimpleSSD {

namespace FTL {

// How many neighbor LPNs may be installed on one demand miss (excluding the
// demand entry itself).
//
// Random / first-in-window: only use already-free slots after reserving one
// for the demand mapping.  Never evict a full CMT to install unused neighbors.
// Sequential (previous demand LPN in the same translation window): allow up to
// windowSize-1 insertions, but cap by half the free slots to avoid evicting
// large fractions of the cache on near-full runs.
inline uint64_t windowFillBudget(uint64_t occupied, uint64_t capacity,
                                 uint64_t windowSize,
                                 bool sequentialWindow) {
  if (capacity <= 1 || windowSize <= 1) {
    return 0;
  }

  if (occupied >= capacity) {
    return 0;
  }

  const uint64_t freeSlots = capacity - occupied;

  if (freeSlots <= 1) {
    return 0;
  }

  const uint64_t maxByWindow = windowSize - 1;

  if (sequentialWindow) {
    // Sequential: allow eviction-backed fills, but never more than half of
    // the free space in one batch.  Previously this path ignored occupancy
    // entirely (returned min(windowSize-1, capacity-1)), causing hundreds of
    // evictions per miss when the cache was near-full.
    return std::min(maxByWindow, freeSlots / 2 + 1);
  }

  // Random miss: only use genuinely free slots (no eviction triggered).
  return std::min(maxByWindow, freeSlots - 1);
}

}  // namespace FTL

}  // namespace SimpleSSD

#endif
