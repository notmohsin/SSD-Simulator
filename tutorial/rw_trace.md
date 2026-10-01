# Read & Write Request Trace — SimpleSSD-Standalone

This document traces a single **READ** and a single **WRITE** request through every simulation layer, identifying the exact file and function touched at each step.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  sim/main.cc  ─  Simulation engine & event loop                │
└───────────────────────────┬─────────────────────────────────────┘
                            │  creates
        ┌───────────────────┴───────────────────┐
        │  IGL  (I/O Generator Layer)           │
        │  igl/request/request_generator.cc     │  ← generates BIO structs
        └───────────────────┬───────────────────┘
                            │  bioEntry.submitIO(bio)
        ┌───────────────────┴───────────────────┐
        │  BIL  (Block I/O Entry)               │
        │  bil/entry.cc                         │  ← queues, tracks latency
        └───────────────────┬───────────────────┘
                            │  pScheduler->submitIO(copy)
        ┌───────────────────┴───────────────────┐
        │  SIL / NVMe Driver                    │
        │  sil/nvme/nvme.cc                     │  ← builds NVMe commands
        └───────────────────┬───────────────────┘
                            │  pController->ringSQTailDoorbell()
        ┌───────────────────┴───────────────────┐
        │  HIL / NVMe Controller                │
        │  simplessd/hil/nvme/controller.cc     │  ← dispatches SQ entries
        └───────────────────┬───────────────────┘
                            │  pSubsystem->submitCommand()
        ┌───────────────────┴───────────────────┐
        │  HIL / NVMe Subsystem                 │
        │  simplessd/hil/nvme/subsystem.cc      │  ← routes to namespace, calls HIL::read/write
        └───────────────────┬───────────────────┘
                            │  iter->submitCommand()  then  pHIL->read/write()
        ┌───────────────────┴───────────────────┐
        │  HIL / NVMe Namespace                 │
        │  simplessd/hil/nvme/namespace.cc      │  ← decodes SLBA/NLB
        └───────────────────┬───────────────────┘
                            │  pHIL->read/write(req)
        ┌───────────────────┴───────────────────┐
        │  HIL  (Host Interface Layer)          │
        │  simplessd/hil/hil.cc                 │  ← CPU cost, calls ICL
        └───────────────────┬───────────────────┘
                            │  pICL->read/write(req, tick)
        ┌───────────────────┴───────────────────┐
        │  ICL  (Internal Cache Layer)          │
        │  simplessd/icl/icl.cc                 │  ← per-page loop
        │  simplessd/icl/generic_cache.cc       │  ← cache hit/miss logic
        └───────────────────┬───────────────────┘
                            │  pFTL->read/write(req, tick)
        ┌───────────────────┴───────────────────┐
        │  FTL  (Flash Translation Layer)       │
        │  simplessd/ftl/ftl.cc                 │  ← wraps PageMapping
        │  simplessd/ftl/page_mapping.cc        │  ← L2P lookup, GC
        └───────────────────┬───────────────────┘
                            │  pPAL->read/write(palReq, tick)
        ┌───────────────────┴───────────────────┐
        │  PAL  (Physical Array Layer)          │
        │  simplessd/pal/pal.cc                 │  ← wraps PALOLD
        │  simplessd/pal/pal_old.cc             │  ← NAND timing model
        └─────────────────────────────────────────┘
```

---

## Layer 0 — Simulation Entry Point

**File:** [`sim/main.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/sim/main.cc)

| Action | Lines | Notes |
|--------|-------|-------|
| Parse args, read config | 70–91 | `simConfig.init(argv[1])` |
| Init SimpleSSD engine | 164 | `initSimpleSSDEngine(&engine, ...)` |
| Create SIL NVMe driver | 173 | `new SIL::NVMe::Driver(engine, ssdConfig)` |
| Create BIL entry | 183–184 | `new BIL::BlockIOEntry(simConfig, engine, pInterface, ...)` |
| Create IGL (RequestGenerator or TraceReplayer) | 199–206 | configured by sim mode |
| `pInterface->init(beginCallback)` | 245 | triggers NVMe init sequence |
| **Event loop** | 255–256 | `while (engine.doNextEvent());` — drives everything |

The event loop fires scheduled callbacks. All I/O latency is modelled by scheduling future events at `tick + latency`.

---

## Layer 1 — IGL: I/O Generator

**File:** [`igl/request/request_generator.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/igl/request/request_generator.cc)

### Entry function: `RequestGenerator::_submitIO(tick)`  (line 210)

```cpp
void RequestGenerator::_submitIO(uint64_t) {
  BIL::BIO bio;
  generateAddress(bio.offset, bio.length);   // sequential or random
  bio.id = io_count++;
  if (nextIOIsRead())  bio.type = BIL::BIO_READ;
  else                 bio.type = BIL::BIO_WRITE;
  bio.callback = iocallback;
  io_depth++;
  bioEntry.submitIO(bio);          // → BIL
  rescheduleSubmit(submissionLatency);
}
```

**Key helpers:**
- `generateAddress()` (line 167) — computes `bio.offset` and `bio.length` using random or sequential mode
- `nextIOIsRead()` (line 194) — decides READ vs WRITE based on `rwmixread` ratio
- `_iocallback(id)` (line 241) — called when BIL signals completion; decrements depth, may call `endCallback()`

---

## Layer 2 — BIL: Block I/O Entry

**File:** [`bil/entry.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/bil/entry.cc)

### `BlockIOEntry::submitIO(BIO &bio)` (line 64)

```cpp
void BlockIOEntry::submitIO(BIO &bio) {
  BIO copy(bio);
  io_count++;
  bio.submittedAt = engine.getCurrentTick();
  ioQueue.push_back(bio);          // save for latency tracking
  copy.callback = callback;        // intercept callback to measure latency
  pScheduler->submitIO(copy);      // → SIL via NoopScheduler
}
```

The `NoopScheduler` (`bil/noop_scheduler.cc`) immediately calls `pDriver->submitIO(copy)` — no reordering.

### `BlockIOEntry::completion(uint64_t id)` (line 79)

Called by SIL when the NVMe command completes. Computes latency, writes to the latency file, then invokes the original `bio.callback` back into IGL.

---

## Layer 3 — SIL: Software Interface Layer (NVMe Driver)

**File:** [`sil/nvme/nvme.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/sil/nvme/nvme.cc)

### `Driver::submitIO(BIL::BIO &bio)` (line 355)

Translates the generic `BIO` into a 64-byte NVMe command:

```cpp
void Driver::submitIO(BIL::BIO &bio) {
  uint32_t cmd[16];
  uint64_t slba = bio.offset / LBAsize;
  uint32_t nlb  = DIVCEIL(bio.length, LBAsize);
  cmd[1] = namespaceID;

  if (bio.type == BIL::BIO_READ) {
      cmd[0] = OPCODE_READ;
      cmd[10] = (uint32_t)slba;  cmd[11] = slba >> 32;
      cmd[12] = nlb - 1;
      prp = new PRP(bio.length);
      prp->getPointer(cmd[6..8]);            // DMA pointer
  } else if (bio.type == BIL::BIO_WRITE) {
      cmd[0] = OPCODE_WRITE;
      ...same SLBA/NLB/PRP encoding...
  }

  submitCommand(1, (uint8_t*)cmd, callback,
                new IOWrapper(bio.id, prp, bio.callback));
}
```

### `Driver::submitCommand(iv, cmd, func, ctx)` (line 305)

```cpp
// Places command bytes into the I/O SQ ring buffer
queue->setData(cmd, 64);
tail = queue->getTail();
pendingCommandList.push_back(CommandEntry(iv, opcode, cid, context, func));
pController->ringSQTailDoorbell(iv, tail, tick);  // → HIL Controller
```

### `Driver::updateInterrupt(iv, post)` (line 549)

Called by the controller when a command completes. Drains the CQ, finds the matching `CommandEntry` by CID, calls `_io()`.

### `Driver::_io(status, ctx)` (line 413)

```cpp
void Driver::_io(uint16_t status, void *context) {
  IOWrapper *wrapper = (IOWrapper *)context;
  wrapper->bioCallback(wrapper->id);   // → BIL::BlockIOEntry::completion()
  delete wrapper->prp;
  delete wrapper;
}
```

### DMA simulation (lines 437–546)

`dmaRead()` / `dmaWrite()` calculate PCIe transfer delay via `PCIExpress::calculateDelay(pcieGen, pcieLane, size)` and schedule events accordingly. Memory is `memcpy`'d through a simulated PRP buffer.

---

## Layer 4 — HIL/NVMe Controller

**File:** [`simplessd/hil/nvme/controller.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/hil/nvme/controller.cc)

### `Controller::ringSQTailDoorbell(qid, tail, tick)` (line 446)

```cpp
void Controller::ringSQTailDoorbell(uint16_t qid, uint16_t tail, uint64_t &) {
  SQueue *pQueue = ppSQueue[qid];
  pQueue->setTail(tail);   // advances tail pointer in submission queue
  // workEvent fires at next tick + workInterval
}
```

### `Controller::work()` / `Controller::handleRequest(now)` (lines ~113–114)

Periodically dequeues entries from all SQueues and calls:

```cpp
pSubsystem->submitCommand(sqEntry, requestFunc);  // → NVMe Subsystem
```

### `Controller::submit(CQEntryWrapper)` (not shown inline)

Called when a command is complete. Writes to the CQ ring, then calls `updateInterrupt()` → `pParent->updateInterrupt()` → `Driver::updateInterrupt()`.

---

## Layer 5 — HIL/NVMe Subsystem

**File:** [`simplessd/hil/nvme/subsystem.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/hil/nvme/subsystem.cc)

### `Subsystem::submitCommand(req, func)` (line 317)

```cpp
// NVM (I/O) commands are routed to the matching namespace:
for (auto &iter : lNamespaces) {
  if (iter->getNSID() == req.entry.namespaceID) {
    execute(CPU::NVME__NAMESPACE, CPU::SUBMIT_COMMAND, doSubmit, pContext);
    // doSubmit calls iter->submitCommand(req, func)
    return;
  }
}
```

### `Subsystem::read(ns, slba, nlblk, func, ctx)` (line 435)

```cpp
void Subsystem::read(...) {
  Request *req = new Request(func, context);
  convertUnit(ns, slba, nlblk, *req);        // LBA → LPN range
  execute(CPU::NVME__SUBSYSTEM, CPU::CONVERT_UNIT, doRead, req);
  // doRead calls: pHIL->read(*req)
}
```

### `Subsystem::write(ns, slba, nlblk, func, ctx)` (line 451)

```cpp
void Subsystem::write(...) {
  Request *req = new Request(func, context);
  convertUnit(ns, slba, nlblk, *req);
  execute(CPU::NVME__SUBSYSTEM, CPU::CONVERT_UNIT, doWrite, req);
  // doWrite calls: pHIL->write(*req)
}
```

### `Subsystem::convertUnit(ns, slba, nlblk, req)` (line 106)

Converts host-visible LBA address space into the internal LPN (Logical Page Number) domain used by HIL/ICL/FTL:

```cpp
slpn = slba / lbaratio;
off  = slba % lbaratio;
nlp  = (nlblk + off + lbaratio - 1) / lbaratio;
req.range.slpn = slpn + info->range.slpn;  // namespace offset
req.range.nlp  = nlp;
req.offset     = off * info->lbaSize;
req.length     = nlblk * info->lbaSize;
```

---

## Layer 6 — HIL/NVMe Namespace

**File:** [`simplessd/hil/nvme/namespace.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/hil/nvme/namespace.cc)

### `Namespace::submitCommand(req, func)` (line 47)

Dispatches by opcode:
```cpp
case OPCODE_WRITE:  write(req, func);  break;
case OPCODE_READ:   read(req, func);   break;
```

### `Namespace::read(req, func)` (line 379)

```cpp
void Namespace::read(SQEntryWrapper &req, RequestFunction &func) {
  uint64_t slba = ((uint64_t)req.entry.dword11 << 32) | req.entry.dword10;
  uint16_t nlb  = (req.entry.dword12 & 0xFFFF) + 1;

  DMAFunction doRead = [this](uint64_t tick, void *context) {
    // called after CPU dispatch cost
    IOContext *pContext = (IOContext *)context;
    pContext->tick = tick;

    pParent->read(this, slba, nlb, dmaDone, pContext);  // → Subsystem::read → HIL::read

    // Concurrently: read from disk image (if enabled) and DMA-write back to host PRP
    pContext->dma->write(0, nlb * info.lbaSize, buffer, dmaDone, context);
  };

  // Wait for CPU dispatch cost, then invoke doRead
  CPUContext *pCPU = new CPUContext(doRead, pContext, CPU::NVME__NAMESPACE, CPU::READ);
  pContext->dma = new PRPList(cfgdata, cpuHandler, pCPU, ...);
}
```

`dmaDone` is called twice (once for SSD completion, once for DMA completion); the response fires only on the 2nd call (`beginAt == 2`).

### `Namespace::write(req, func)` (line 285)

```cpp
// doRead lambda (after CPU cost):
pContext->dma->read(0, nlb * info.lbaSize, buffer, dmaDone, context); // DMA read from host
pParent->write(this, slba, nlb, dmaDone, context);                    // → Subsystem::write → HIL::write
// Again, dmaDone fires twice; response sent on 2nd
```

---

## Layer 7 — HIL (Host Interface Layer)

**File:** [`simplessd/hil/hil.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/hil/hil.cc)

### `HIL::read(Request &req)` (line 40)

```cpp
void HIL::read(Request &req) {
  DMAFunction doRead = [this](uint64_t beginAt, void *context) {
    auto pReq = (Request *)context;
    pReq->reqID = ++reqCount;

    ICL::Request reqInternal(*pReq);
    pICL->read(reqInternal, tick);     // → ICL

    stat.request[0]++;
    stat.iosize[0] += pReq->length;
    updateBusyTime(0, beginAt, tick);

    pReq->finishedAt = tick;
    completionQueue.push(*pReq);
    updateCompletion();
    delete pReq;
  };

  execute(CPU::HIL, CPU::READ, doRead, new Request(req));
  // execute() applies CPU latency before calling doRead
}
```

### `HIL::write(Request &req)` (line 71)

```cpp
void HIL::write(Request &req) {
  DMAFunction doWrite = [this](uint64_t beginAt, void *context) {
    auto pReq = (Request *)context;
    pReq->reqID = ++reqCount;

    ICL::Request reqInternal(*pReq);
    pICL->write(reqInternal, tick);    // → ICL

    stat.request[1]++;
    stat.iosize[1] += pReq->length;
    updateBusyTime(1, beginAt, tick);

    pReq->finishedAt = tick;
    completionQueue.push(*pReq);
    updateCompletion();
    delete pReq;
  };

  execute(CPU::HIL, CPU::WRITE, doWrite, new Request(req));
}
```

### `HIL::completion()` (line 204)

Fires at `finishedAt` tick. Drains `completionQueue`, calling `req.function(tick, req.context)` to propagate completion back up to the NVMe namespace's `dmaDone`.

---

## Layer 8 — ICL (Internal Cache Layer)

### `icl/icl.cc` — `ICL::read / ICL::write`

**File:** [`simplessd/icl/icl.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/icl/icl.cc)

`ICL::read` (line 66) iterates over each logical page in the request and calls `pCache->read(reqInternal, beginAt)`. Similarly `ICL::write` (line 98) calls `pCache->write(...)`. The maximum completion tick across all sub-pages is tracked and returned.

```cpp
for (uint64_t i = 0; i < req.range.nlp; i++) {
  reqInternal.range.slpn = req.range.slpn + i;
  reqInternal.length = MIN(reqRemain, logicalPageSize - reqInternal.offset);
  pCache->read(reqInternal, beginAt);      // per-page cache access
  finishedAt = MAX(finishedAt, beginAt);
}
tick = finishedAt;
tick += applyLatency(CPU::ICL, CPU::READ); // CPU cost
```

---

### `icl/generic_cache.cc` — Cache Hit/Miss

**File:** [`simplessd/icl/generic_cache.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/icl/generic_cache.cc)

#### READ path `GenericCache::read(req, tick)` (line 348)

```
1. calcSetIndex(slpn) → set index
2. getValidWay(slpn, tick) → way index (waySize = miss)

── CACHE HIT (wayIdx != waySize) ──
   pDRAM->read(&cacheLine, req.length, tick)   // DRAM latency
   update lastAccessed
   [optional prefetch trigger]

── CACHE MISS ──
   getEmptyWay() or evictFunction()
   if dirty eviction needed: evictData[row][col] = line
   evictCache(tick)             // flush dirty lines → pFTL->write
   pFTL->read(reqInternal, beginAt)   // → FTL read
   pDRAM->write(pLine, lineSize, dramAt)  // bring into DRAM/cache
   update cache metadata
```

#### WRITE path `GenericCache::write(req, tick)` (line 548)

```
FTL::Request reqInternal(lineCountInSuperPage, req);

if (req.length < lineSize):  // partial write → dirty
    dirty = true
else:
    pFTL->write(reqInternal, flash)   // full page → write-through to NAND

if (useWriteCaching):
    getValidWay() → hit or miss
    ── HIT: update dirty bit, DRAM write, update timestamps
    ── MISS (empty way): fill empty way, DRAM write
    ── MISS (no empty way): select victim, evictCache(true), get empty way, DRAM write
```

---

## Layer 9 — FTL (Flash Translation Layer)

### `ftl/ftl.cc`

**File:** [`simplessd/ftl/ftl.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/ftl/ftl.cc)

Thin wrapper that delegates to the PageMapping implementation:

```cpp
void FTL::read(Request &req, uint64_t &tick) {
  pFTL->read(req, tick);                        // → PageMapping::read
  tick += applyLatency(CPU::FTL, CPU::READ);
}

void FTL::write(Request &req, uint64_t &tick) {
  pFTL->write(req, tick);                       // → PageMapping::write
  tick += applyLatency(CPU::FTL, CPU::WRITE);
}
```

---

### `ftl/page_mapping.cc` — L2P Table + GC

**File:** [`simplessd/ftl/page_mapping.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/ftl/page_mapping.cc)

#### READ: `PageMapping::readInternal(req, tick)` (line 621)

```cpp
auto mappingList = table.find(req.lpn);       // L2P lookup (hash map)
pDRAM->read(&(*mappingList), 8*count, tick);  // mapping table in DRAM

for each ioFlag bit:
    palRequest.blockIndex = mapping.first;    // physical block
    palRequest.pageIndex  = mapping.second;   // physical page
    block->second.read(palRequest.pageIndex, idx, beginAt); // update block state
    pPAL->read(palRequest, beginAt);          // → PAL
    finishedAt = MAX(finishedAt, beginAt);

tick = finishedAt;
tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::READ_INTERNAL);
```

#### WRITE: `PageMapping::writeInternal(req, tick, sendToPAL=true)` (line 674)

```cpp
// 1. Invalidate old mapping (if LPN already mapped)
auto mappingList = table.find(req.lpn);
for each idx: block->second.invalidate(old_page, idx);

// 2. Get free block for new data
block = blocks.find(getLastFreeBlock(req.ioFlag));

// 3. DRAM: read + write mapping table entry
pDRAM->read(&(*mappingList), 8*count, tick);
pDRAM->write(&(*mappingList), 8*count, tick);

// 4. Write to PAL
palRequest.blockIndex = block->first;
palRequest.pageIndex  = block->second.getNextWritePageIndex(idx);
pPAL->write(palRequest, beginAt);             // → PAL

// 5. Trigger GC if freeBlockRatio() < gcThreshold
if (...) {
    selectVictimBlock(list, tick);            // greedy/random/cost-benefit
    doGarbageCollection(list, tick);          // PAL read → write → erase
}
tick += applyLatency(CPU::FTL__PAGE_MAPPING, CPU::WRITE_INTERNAL);
```

#### GC: `PageMapping::doGarbageCollection(blocksToReclaim, tick)` (line 493)

```
For each victim block:
  For each valid page:
    readRequests.push_back(...)
    update table: mapping → new block/page
    writeRequests.push_back(...)
  eraseRequests.push_back(...)

Execute:
  for readReq:  pPAL->read(iter, beginAt)
  for writeReq: pPAL->write(iter, beginAt)
  for eraseReq: eraseInternal(iter, beginAt)  → pPAL->erase()
```

---

## Layer 10 — PAL (Physical Array Layer)

**File:** [`simplessd/pal/pal.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/pal/pal.cc)
**Impl:** [`simplessd/pal/pal_old.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/pal/pal_old.cc)

`PAL` is a thin adapter:

```cpp
void PAL::read(Request &req, uint64_t &tick)  { pPAL->read(req, tick); }
void PAL::write(Request &req, uint64_t &tick) { pPAL->write(req, tick); }
void PAL::erase(Request &req, uint64_t &tick) { pPAL->erase(req, tick); }
```

`PALOLD` (`pal_old.cc`) models NAND channel/way/die/plane scheduling and adds:
- **Read latency**: `tR` (NAND read time per plane × parallelism)
- **Write latency**: `tPROG` (NAND program time)
- **Erase latency**: `tBERS` (NAND block erase time)

It increments `tick` by the calculated NAND timing. This is the lowest level of the simulation and the final sink for latency accounting.

---

## Complete Call Chain Summary

### READ Request

```
IGL::RequestGenerator::_submitIO()
  → BIL::BlockIOEntry::submitIO()
    → BIL::NoopScheduler::submitIO()
      → SIL::NVMe::Driver::submitIO()          [builds OPCODE_READ NVMe cmd]
        → SIL::NVMe::Driver::submitCommand()
          → HIL::NVMe::Controller::ringSQTailDoorbell()
            → [work event fires]
            → HIL::NVMe::Controller::handleRequest()
              → HIL::NVMe::Subsystem::submitCommand()
                → HIL::NVMe::Namespace::submitCommand()
                  → HIL::NVMe::Namespace::read()
                    → HIL::NVMe::Subsystem::read()
                      → Subsystem::convertUnit()     [LBA → LPN]
                      → HIL::HIL::read()             [CPU cost]
                        → ICL::ICL::read()           [per-page loop]
                          → ICL::GenericCache::read()
                            [HIT]  → pDRAM->read()
                            [MISS] → pFTL->read()
                                       → FTL::FTL::read()
                                         → FTL::PageMapping::read()
                                           → PageMapping::readInternal()
                                             → pDRAM->read() [mapping table]
                                             → PAL::PAL::read()
                                               → PALOLD::read()  ← NAND tR
```

*Completion path (returns up the call stack via callbacks/events):*

```
PALOLD::read() returns tick
→ PageMapping::readInternal sets tick
→ FTL::FTL::read adds CPU latency
→ GenericCache updates cache line, adds DRAM write latency
→ ICL::ICL::read takes max tick, adds CPU latency
→ HIL::HIL::read pushes to completionQueue
→ [completionEvent fires at finishedAt]
→ HIL::HIL::completion() → req.function() → Namespace dmaDone
→ [dmaDone called 2nd time → Namespace calls func(resp)]
→ Controller::submit(CQEntry)
→ Driver::updateInterrupt()
→ Driver::_io() → wrapper->bioCallback()
→ BIL::BlockIOEntry::completion()
→ bio.callback() → IGL::RequestGenerator::_iocallback()
```

---

### WRITE Request

```
IGL::RequestGenerator::_submitIO()
  → BIL::BlockIOEntry::submitIO()
    → SIL::NVMe::Driver::submitIO()           [builds OPCODE_WRITE NVMe cmd]
      → SIL::NVMe::Driver::submitCommand()
        → HIL::NVMe::Controller::ringSQTailDoorbell()
          → [work event → handleRequest]
          → HIL::NVMe::Subsystem::submitCommand()
            → HIL::NVMe::Namespace::submitCommand()
              → HIL::NVMe::Namespace::write()
                → [DMA read from host PRP]  ← PCIe latency via Driver::dmaRead
                → HIL::NVMe::Subsystem::write()
                  → Subsystem::convertUnit()    [LBA → LPN]
                  → HIL::HIL::write()           [CPU cost]
                    → ICL::ICL::write()         [per-page loop]
                      → ICL::GenericCache::write()
                        [full page]   → pFTL->write() immediately
                        [partial]     → mark dirty, defer to eviction
                        [cache miss + full] → evictCache() → pFTL->write(dirty lines)
                          → FTL::FTL::write()
                            → FTL::PageMapping::write()
                              → PageMapping::writeInternal()
                                → table.find(lpn) → invalidate old mapping
                                → getLastFreeBlock()
                                → pDRAM->read/write() [mapping table]
                                → PAL::PAL::write()
                                  → PALOLD::write()  ← NAND tPROG
                                [if GC needed]
                                  → doGarbageCollection()
                                    → pPAL->read, pPAL->write, pPAL->erase
```

*Completion path mirrors the read path — callbacks propagate up from PALOLD back through FTL → ICL → HIL → Namespace → Controller → Driver → BIL → IGL.*

---

## Files Touched by a READ or WRITE Request

| # | File | Role |
|---|------|------|
| 1 | [`sim/main.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/sim/main.cc) | Init, event loop |
| 2 | [`igl/request/request_generator.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/igl/request/request_generator.cc) | Generate BIO, callback |
| 3 | [`bil/entry.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/bil/entry.cc) | Queue BIO, measure latency |
| 4 | [`bil/noop_scheduler.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/bil/noop_scheduler.cc) | Pass-through scheduler |
| 5 | [`sil/nvme/nvme.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/sil/nvme/nvme.cc) | NVMe command construction, DMA, interrupt |
| 6 | [`sil/nvme/prp.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/sil/nvme/prp.cc) | PRP (Physical Region Page) DMA buffer |
| 7 | [`simplessd/hil/nvme/controller.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/hil/nvme/controller.cc) | SQ/CQ management, doorbell, dispatch |
| 8 | [`simplessd/hil/nvme/subsystem.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/hil/nvme/subsystem.cc) | Command routing, LBA→LPN, calls HIL |
| 9 | [`simplessd/hil/nvme/namespace.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/hil/nvme/namespace.cc) | Opcode decode, DMA orchestration |
| 10 | [`simplessd/hil/hil.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/hil/hil.cc) | CPU cost, completion queue, calls ICL |
| 11 | [`simplessd/icl/icl.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/icl/icl.cc) | Per-page loop, CPU cost, calls cache |
| 12 | [`simplessd/icl/generic_cache.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/icl/generic_cache.cc) | Set-associative cache, eviction, prefetch |
| 13 | [`simplessd/ftl/ftl.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/ftl/ftl.cc) | FTL wrapper + CPU cost |
| 14 | [`simplessd/ftl/page_mapping.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/ftl/page_mapping.cc) | L2P table, GC victim selection & collection |
| 15 | [`simplessd/pal/pal.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/pal/pal.cc) | PAL adapter |
| 16 | [`simplessd/pal/pal_old.cc`](file:///home/mohsin/Mohsin/Second%20Year/SIP%202026/SimpleSSD-Standalone/simplessd/pal/pal_old.cc) | NAND timing model (tR / tPROG / tBERS) |
