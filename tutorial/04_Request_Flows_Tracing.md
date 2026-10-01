# Tutorial 4: Request Flows Tracing

> **Deeper version available.** [`architecture/08_traces.md`](architecture/08_traces.md) traces the same paths with per-hop tick accounting and verified `file:line` citations, including a write that trips garbage collection.

To truly understand the simulator, you need to be able to trace how a block request transforms into simulated time, NAND activity, and metadata movement. 

Let's walk through the call path of a single 4KiB Write request.

## The Lifecycle of a Write Request

Assume we are using the direct interface (`Interface = 0`) and writing 4KiB data.

### 1. Generation and Block I/O (BIL)
1. `RequestGenerator::_submitIO` generates a request and creates a `BIL::BIO` object with the offset, length, and a callback.
2. `BlockIOEntry::submitIO` records the current simulated `tick` (time) and sends it to the scheduler.
3. `NoopScheduler::submitIO` passes it directly to the SIL.

### 2. Simulator Interface Layer (SIL)
1. `SIL::None::Driver::submitIO` translates the byte offset into a Logical Page Number (LPN) and offset. It constructs a `HIL::Request` and calls `pHIL->write()`.

### 3. Host Interface Layer (HIL)
1. `HIL::write` schedules a CPU job in the simulator event engine. 
2. The CPU job executes, assigning an internal ID and passing it to the ICL.

### 4. Internal Cache Layer (ICL)
1. `ICL::write` splits the request across logical pages if it crosses a page boundary.
2. For each logical page, it calls `GenericCache::write()`.
3. `GenericCache` checks if the write hits an existing cache line or if it needs to evict an old dirty line. A dirty line eviction or a full cache bypass will call `pFTL->write()`.

### 5. Flash Translation Layer (FTL)
1. `FTL::write` applies FTL CPU latency.
2. `PageMapping::writeInternal` is called. This is where the magic happens!
   - It checks the mapping table in DRAM.
   - If the LPN was previously written, it **invalidates** the old physical page.
   - It creates a new mapping entry and chooses a new free block and page.
   - It updates the mapping table.
   - It calls `pPAL->write()` to perform the physical programming.
   - **Crucially:** It checks the free block ratio. If it's too low, it triggers Garbage Collection!

### 6. Parallelism Abstraction Layer (PAL)
1. `PAL::write` models the exact NAND program timing, DMA timing, and handles the parallelism (checking which channel/die is currently busy).

### 7. Completion Path
1. Once the simulated `finishedAt` time is reached, the HIL schedules a completion event.
2. `BlockIOEntry::completion` calculates the latency (`current tick` - `submittedAt`), updates latency statistics, and calls the original `RequestGenerator` callback.
3. `RequestGenerator` decrements its outstanding I/O count and maybe schedules the next request.

> [!TIP]
> This trace is worth internalizing. Almost any modification you make to the simulator for research will involve modifying just one piece of this chain!

In our final tutorial, we'll map out how you can change this codebase to implement your own research ideas.
