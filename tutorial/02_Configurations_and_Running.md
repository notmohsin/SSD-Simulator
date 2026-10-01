# Tutorial 2: Configurations and Running SimpleSSD-Standalone

To run experiments in SimpleSSD-Standalone, you need to configure two different things: the experiment itself (the workload) and the hardware you are testing (the SSD). 

This is why there are two configuration files!

## The Two Config Files

### 1. The Workload Config (`config/sample.cfg`)
This file defines **what questions you are asking**. It configures the synthetic workload generator, trace replay settings, queue depth, and logging behavior.

**Key Settings (`[global]` section):**
- `Mode = 0`: Use synthetic generator (1 for trace replay).
- `Interface = 0`: Use direct interface (skips NVMe protocol overhead). `Interface = 1` enables NVMe.
- `LogPeriod`: How often to print periodic stats.

**Key Settings (`[generator]` section):**
- `readwrite`: Type of workload (`read`, `write`, `randread`, `randwrite`, `randrw`).
- `iodepth`: Queue depth (number of outstanding I/Os). Higher values expose internal SSD parallelism.
- `blocksize`: Size of each I/O (e.g., `4K`).
- `io_size`: Total amount of data to issue.

### 2. The SSD Config (`simplessd/config/sample.cfg`)
This file defines **the hardware being questioned**. It models the SSD's CPU, cache, DRAM, FTL behavior, and NAND physical geometry.

**Key Sections:**
- `[pal]`: Configures NAND geometry (`Channel`, `Package`, `Die`, `Plane`, `Block`, `Page`). This determines the raw physical capacity and parallelism.
- `[ftl]`: Configures Garbage Collection policies (`EvictPolicy`, `GCThreshold`) and Over-Provisioning (`OverProvisioningRatio`).
- `[icl]`: Configures Cache behavior (`EnableReadCache`, `EnableWriteCache`, `CacheSize`).
- `[dram]`: Configures DRAM timing parameters.

## Running the Simulator

The standalone executable takes three arguments:
1. Workload configuration file.
2. SSD configuration file.
3. Output directory for logs (e.g., `/tmp`).

**Example Command:**
```bash
./simplessd-standalone config/sample.cfg simplessd/config/sample.cfg /tmp
```

## Interpreting Output Statistics

When the simulation completes, it prints a large tree of statistics.

> [!WARNING]
> If you run a read-only workload on an empty SSD, you might see `pal.read.count = 0`. Why? If the FTL has no mapping for a logical page (because it was never written), it won't perform a physical NAND read! Or, the `ICL` might serve the read entirely from cache.

When debugging surprising stats, always ask: **"Which layer could have hidden the lower layer?"**
- High cache hit rate hides NAND reads.
- An empty mapping table hides NAND reads.
- The `None` interface hides NVMe overhead.

In the next tutorial, we will dive deep into how NAND flash actually works internally, including FTL mappings and Garbage Collection.
