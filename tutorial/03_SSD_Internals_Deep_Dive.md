# Tutorial 3: SSD Internals Deep Dive

In this lesson, we will dive into the most important flash memory concepts and see how SimpleSSD models them. 

## Logical vs Physical

The host operating system sees **logical addresses** (e.g., LBA, Logical Block Address). It might ask to "read 4096 bytes at byte offset 8192".
Inside the SSD, the data is stored in **physical NAND locations**. The FTL (Flash Translation Layer) maintains a mapping table to convert a Logical Page Number (LPN) into a Physical block/page/plane/die/channel.

## The Golden Rule: NAND Cannot Overwrite In Place

This is the most critical difference between an HDD and an SSD.
A hard drive can overwrite a sector directly. **NAND flash cannot.**
NAND operates on three different granularities:
1. **Read page:** Fine-grained (nanoseconds to microseconds).
2. **Program page:** Fine-grained, but data can **only be written into an erased page**. (microseconds to milliseconds).
3. **Erase block:** Coarse-grained. Erases many pages at once (milliseconds).

> [!CAUTION]
> Because you cannot overwrite in place, overwriting a logical page forces the SSD to:
> 1. Write the new data to a *fresh, free* physical page.
> 2. Mark the *old* physical page as "invalid".
> 3. Later, perform Garbage Collection to reclaim blocks full of invalid pages.

## NAND Geometry and Simulator Abstractions

Physical NAND is structured hierarchically:
`Cell -> Page -> Block -> Plane -> Die -> Package -> Channel -> SSD`

To manage this complex parallelism efficiently, the simulator creates two abstractions: **Superpages** and **Superblocks**. 
By grouping physical structures into these larger logical units, the model can express operations that span parallel NAND units (like striping writes across multiple channels and dies) without forcing the upper layers to juggle exact coordinates.

## Over-Provisioning and Garbage Collection

In `simplessd/config/sample.cfg`, you will see `OverProvisioningRatio = 0.25`. This means 25% of the total physical capacity is hidden from the host as "spare blocks". 
These spare blocks are critical for the out-of-place write mechanism.

### Garbage Collection (GC) Lifecycle
When the number of free blocks drops below a configured `GCThreshold` (e.g., 0.05), Garbage Collection begins.
1. `PageMapping::selectVictimBlock()` selects a victim block full of invalid pages.
2. The SSD finds the still-valid pages in that block.
3. It reads those valid pages out and writes them elsewhere (consuming extra physical writes—this is **Write Amplification**).
4. Finally, the victim block is erased and returned to the free list.

Different eviction policies (Greedy, Cost-Benefit, Random) can be configured via `EvictPolicy`.

## Caching and Prefetching

The Internal Cache Layer (ICL) sits above the FTL. It can serve reads from simulated SSD DRAM without touching NAND. If the ICL detects a sequential read pattern, it may issue **prefetch** operations.
Writes are also cached. A partial write may become a "dirty" cache line, which is eventually evicted and written back to the FTL.

In the next tutorial, we will trace the exact code path a request takes as it flows through these systems!
