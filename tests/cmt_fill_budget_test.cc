#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "ftl/cmt_fill_budget.hh"

using SimpleSSD::FTL::windowFillBudget;

static int failures = 0;

static void expect_eq(uint64_t got, uint64_t want, const char *name) {
  if (got != want) {
    std::fprintf(stderr, "FAIL %s: got %llu want %llu\n", name,
                 (unsigned long long)got, (unsigned long long)want);
    failures++;
  }
}

int main() {
  const uint64_t cap = 4096;
  const uint64_t win = 512;

  expect_eq(windowFillBudget(0, 1, win, false), 0, "tiny_capacity");
  expect_eq(windowFillBudget(0, cap, 1, true), 0, "tiny_window");

  expect_eq(windowFillBudget(cap, cap, win, false), 0, "full_random");
  expect_eq(windowFillBudget(cap - 1, cap, win, false), 0,
            "one_free_is_demand_only");

  expect_eq(windowFillBudget(0, cap, win, false), 511, "empty_random_fills_free");
  expect_eq(windowFillBudget(cap - 100, cap, win, false), 99,
            "partial_free_random");

  expect_eq(windowFillBudget(cap, cap, win, true), 511, "full_sequential_window");
  expect_eq(windowFillBudget(cap - 1, cap, win, true), 511,
            "sequential_may_evict");

  if (failures != 0) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return EXIT_FAILURE;
  }

  std::printf("cmt_fill_budget_test: PASS\n");
  return EXIT_SUCCESS;
}
