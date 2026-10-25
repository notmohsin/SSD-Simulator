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
// Sequential (previous demand LPN in the same translation window): allow
// eviction-backed fills up to windowSize-1 entries, capped so that no single
// miss evicts more than half the cache.  This lets a sequential scan amortize
// the translation-page read across the whole window even when the cache is
// full, which is the primary benefit of window fill.
inline uint64_t windowFillBudget(uint64_t occupied, uint64_t capacity,
                                 uint64_t windowSize,
                                 bool sequentialWindow) {
  if (capacity <= 1 || windowSize <= 1) {
    return 0;
  }

  const uint64_t maxByWindow = windowSize - 1;

  if (sequentialWindow) {
    // Sequential: allow eviction-backed fills.  Cap at half the cache so a
    // single miss never displaces more than 50% of resident entries.
    // When free slots exist, use those first (freeSlots/2 + 1).
    // When full, allow up to capacity/2 evictions.
    if (occupied >= capacity) {
      return std::min(maxByWindow, capacity / 2);
    }
    const uint64_t freeSlots = capacity - occupied;
    return std::min(maxByWindow, std::max(freeSlots / 2 + 1, capacity / 2));
  }

  // Random / first-in-window: only use genuinely free slots (no eviction).
  if (occupied >= capacity) {
    return 0;
  }

  const uint64_t freeSlots = capacity - occupied;
  if (freeSlots <= 1) {
    return 0;
  }

  return std::min(maxByWindow, freeSlots - 1);
}

}  // namespace FTL

}  // namespace SimpleSSD

#endif
