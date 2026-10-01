<div align="center">

# Into the Flash: A Report on SSD Systems Research at IIT Ropar

**Final Report of Summer Internship Program**

**Presented To**
Prof. Lokendra Vishwakarma (FLAME University) & Prof. TV Kalyan (IIT Ropar)

**On 10th of July 2026**

**By**
Sheikh Mohsin Shafi
240341

**In Partial Fulfillment of the Requirements for the UG Program (2024-2027)**
**FLAME University, Pune**

</div>

<div style="page-break-after: always;"></div>

## Internship Completion Certificate

*(To be issued on Organization letterhead and inserted here prior to final submission. The certificate will state that Sheikh Mohsin Shafi successfully completed a full-time, in-person/hybrid research internship at IIT Ropar from May 11 to August 8, 2026, under the supervision of Prof. Venkata Kalyan Tavva and PhD scholar Waqar Hassan Mir.)*

<div style="page-break-after: always;"></div>

## Table of Contents
[Abstract](#abstract)
1. [Introduction](#1-introduction)
2. [Secondary Research](#2-secondary-research)
   2.1. [NAND Flash Memory Physics and FTL Internals](#21-nand-flash-memory-physics-and-ftl-internals)
   2.2. [Advanced DRAM Cache Management](#22-advanced-dram-cache-management)
   2.3. [Firmware-Level Security and Ransomware Defense](#23-firmware-level-security-and-ransomware-defense)
3. [Activities Undertaken](#3-activities-undertaken)
4. [Project Outcomes/Findings from the Assigned Work](#4-project-outcomesfindings-from-the-assigned-work)
5. [Personal Learning/Reflections](#5-personal-learningreflections)
6. [Limitations of the Internship](#6-limitations-of-the-internship)
[References](#references)
[Appendix](#appendix)

<div style="page-break-after: always;"></div>

## Abstract

This report presents the final, comprehensive account of my research internship under the supervision of Prof. Venkata Kalyan Tavva at the Indian Institute of Technology Ropar, conducted from May 11 to August 8, 2026, in close collaboration with PhD scholar Waqar Hassan Mir. The internship focused heavily on persistent storage systems, specifically delving into the intricacies of Solid-State Drive (SSD) architecture, firmware design, and hardware-level cybersecurity. The initial phase of the internship involved building a solid foundational knowledge base through literature encompassing NAND flash physics, Flash Translation Layer (FTL) internals, and the dynamics of DRAM caching (Arpaci-Dusseau & Arpaci-Dusseau, 2018; Zhu et al., 2020). Subsequently, I undertook rigorous practical work by building, configuring, and profiling the SimpleSSD-Standalone 2.0 full-system simulator (Gouk et al., 2018; SimpleSSD Authors, n.d.), an industry-standard emulation tool used for advanced academic storage research. Following this practical exposure, I performed in-depth secondary research and critical reviews on recent high-impact publications from Prof. Kalyan's group. This included evaluating cache optimization algorithms like RASP (Mir et al., 2026) and FatCBST (Alapati et al., 2017), alongside sophisticated hardware-level ransomware defenses such as CARDR (Mir et al., 2024) and SrFTL (Zhu et al., 2025). This intense immersion provided me with a rigorous introduction to the world of academic research, systems engineering, and hardware security, paving a definitive path for my future academic pursuits and higher studies in systems architecture.

## 1. Introduction

The Indian Institute of Technology Ropar (IIT Ropar) is a premier engineering and research institute in India, renowned for its commitment to fostering cutting-edge innovation and technological advancement. My summer internship was hosted within the esteemed Department of Computer Science and Engineering, specifically under the Computer Architecture and Systems Research Lab headed by Prof. Venkata Kalyan Tavva. This lab is at the forefront of systems research, focusing predominantly on memory systems, solid-state drive (SSD) architectures, concurrent data structures, and the emerging field of hardware-level cybersecurity. 

In modern computing paradigms, SSDs have completely revolutionized storage performance by replacing mechanical read/write heads with non-volatile NAND flash memory. However, this transition has introduced a host of complex software and firmware challenges, ranging from uneven flash cell wear and garbage collection overheads to severe vulnerabilities against data-extorting malware. The primary objective of my summer internship was to delve deeply into this SSD systems research, transitioning from a theoretical student with no prior background in hardware architecture to an active contributor capable of running, evaluating, and extending complex SSD simulators. 

My assigned work was multi-faceted, encompassing both theoretical study and practical systems engineering. Initially, the work involved a rigorous literature review to understand how modern SSDs operate internally, manage memory through translation layers, and defend against malicious attacks (Zhu et al., 2020). Subsequently, I was tasked with compiling, building, and configuring the SimpleSSD-Standalone 2.0 simulator (Gouk et al., 2018; SimpleSSD Authors, n.d.)—a complex C++ based simulation framework used extensively in academia to accurately model full-stack SSD operations. A significant portion of my responsibilities also included reviewing recent publications by my mentors (Alapati et al., 2017; Mir et al., 2024; Mir et al., 2026; Zhu et al., 2025) to synthesize their findings and propose logical extensions for future research.

## 2. Secondary Research

The foundational stage of my research required comprehending the intricate and often counterintuitive architecture of modern storage systems. This base knowledge was absolutely vital to fully appreciate the complex algorithms, cache optimization policies, and cybersecurity defenses proposed in the primary research papers I reviewed.

### 2.1. NAND Flash Memory Physics and FTL Internals

Unlike traditional Hard Disk Drives (HDDs) that overwrite data magnetically in place, NAND flash memory exhibits significant operational asymmetries that govern how all SSDs must be designed. Flash memory is hierarchically organized into channels, chips, dies, planes, blocks, and pages. While read and program (write) operations occur at the page level (typically 4KB to 16KB), erase operations can only occur at the much larger block level (which often contains hundreds of pages). 

Crucially, flash memory imposes an "erase-before-write" physical constraint. This means a page cannot be directly overwritten with new data once it has been programmed. Instead, modern SSDs must perform "out-of-place updates." When the host OS modifies a file, the SSD writes the new data to an entirely different, pre-erased clean page and simply marks the old page containing the obsolete data as "invalid" (Arpaci-Dusseau & Arpaci-Dusseau, 2018).

This physical limitation necessitates a highly complex intermediate software layer running on the SSD's internal processor known as the Flash Translation Layer (FTL). The FTL abstracts the complexities of the raw flash memory, presenting a standard block-device interface to the host operating system. The FTL is primarily responsible for:
*   **Logical-to-Physical (L2P) Mapping:** Translating Logical Block Addresses (LBAs) provided by the host to exact Physical Page Addresses (PPAs) on the flash chips.
*   **Garbage Collection (GC):** As invalid pages accumulate, the SSD runs out of free space. GC periodically reclaims this space by reading the remaining valid pages from a heavily fragmented block, rewriting them to a new clean block, and then erasing the old block entirely (Zhu et al., 2020). This process, unfortunately, causes "write amplification," where the SSD internally writes more data than the host explicitly requested.
*   **Wear Leveling:** Individual flash cells can only endure a limited number of Program/Erase (P/E) cycles before failing. The FTL employs wear leveling algorithms to distribute erase cycles evenly across all flash blocks, ensuring that no single block dies prematurely, thereby maximizing the SSD's overall lifespan.

### 2.2. Advanced DRAM Cache Management

To mask the high latency of NAND flash program and erase operations, and to reduce the wear on flash cells, high-performance SSDs incorporate an onboard volatile DRAM cache. The DRAM cache absorbs bursty write traffic from the host and serves frequently accessed read data. However, efficiently managing this cache is incredibly challenging. Inefficient caching policies can lead to severe "cache pollution," which is particularly exacerbated by "Single-Use" (SU) pages. These are data pages that are read or written exactly once by the host and never accessed again. When SU pages are cached, they needlessly evict highly valuable frequently-accessed data (dirty evictions), ultimately hurting the SSD's performance and increasing the write amplification factor.

To address this specific bottleneck, Mir et al. (2026) proposed **RASP** (Region-Aware Single-Use Page Predictor). RASP is a lightweight, firmware-level predictive mechanism. The authors exploited the spatial locality of LBAs, observing that SU pages tend to cluster together in contiguous address ranges due to the way operating systems write large logs or multimedia files. Instead of tracking the history of individual pages, which would require massive memory overhead, RASP divides the entire LBA space into coarse-grained regions and maintains a highly compact, bounded Region Tracking Table (RTT). Through confidence counters, RASP dynamically predicts whether incoming data belongs to a Single-Use or Multi-Use region. Experimental results showed that RASP achieved an impressive 97.67% recall and 72.17% accuracy, successfully bypassing the DRAM cache for SU pages. This innovation reduced flash writes by an average of 8.04% and decreased workload execution time by 11.71% (Mir et al., 2026).

Furthermore, optimizing the concurrent data structures running on the SSD's internal controllers is equally critical. For instance, the **FatCBST** concurrent binary tree structure (Alapati et al., 2017) demonstrated that using "fatnodes" (an array of values per node rather than a single value) can drastically reduce tree height. This approach minimizes synchronization lock overheads (`succLock` and `treeLock`) across concurrent threads and dramatically improves Last-Level Cache (LLC) locality in multi-core Non-Uniform Memory Access (NUMA) systems, resulting in vastly superior throughput for highly contentious workloads.

### 2.3. Firmware-Level Security and Ransomware Defense

Ransomware is an evolving cybersecurity threat that encrypts victim data and demands exorbitant payments for the decryption key. While many defenses currently operate at the OS or kernel level, they are fundamentally vulnerable to privilege escalation attacks—if a sophisticated attacker gains "root" or administrative access, they can simply terminate the OS-level antivirus software. Because the SSD operates its own isolated processor and firmware, firmware-level defenses embedded directly within the SSD represent a far more robust, tamper-proof line of defense.

To this end, Mir et al. (2024) introduced **CARDR** (Cache Assisted Ransomware Detection and Recovery), an SSD-level defense mechanism that cleverly leverages the DRAM cache for both early detection and rapid data recovery. CARDR extracts real-time features from both incoming host I/O requests and internal DRAM cache activities. It tracks metrics such as Cache Overwrites, Cumulative Cache Overwrites, and Dirty Evictions, feeding them into a lightweight machine-learning decision tree embedded right in the SSD controller. Because ransomware fundamentally relies on a "read-before-overwrite" pattern to steal and encrypt files, CARDR introduces a `ReadBit` flag in the L2P mapping table. If an LBA is written to shortly after being read, it triggers suspicion. CARDR also temporarily holds the physical addresses of these old pages in a specialized recovery queue. By acting immediately before the DRAM cache is flushed, CARDR reduces the size of the recovery queue by ~42% and successfully detects zero-day ransomware threats in approximately 11 seconds (Mir et al., 2024).

Building on the necessity for holistic firmware security, Zhu et al. (2025) proposed **SrFTL** (Semantic-reinforced FTL). A major flaw in traditional FTL defenses is the "semantic gap"—the SSD only sees raw blocks (0s and 1s) and has no concept of files, directories, or user permissions. SrFTL bridges this semantic gap by integrating a Trusted Execution Environment (TEE), specifically utilizing Intel SGX hardware enclaves. SrFTL effectively parses raw filesystem metadata (such as ext4 superblocks and inode tables) inside the secure enclave to extract file-level semantics, like abrupt file type changes or mass deletions. By combining these semantic heuristics with deep data randomness tests (fine-grained entropy calculations and chi-square testing), SrFTL achieves 100% detection accuracy with zero false positives across numerous real-world ransomware families, adding merely a 1.5% performance overhead to the SSD's normal operations (Zhu et al., 2025).

## 3. Activities Undertaken

My internship followed a highly structured, progressive timeline designed to incrementally build my expertise from foundational theoretical knowledge to practical simulation engineering and advanced academic critique.

*   **Foundation Building (Weeks 1-3):** I spent the initial weeks deeply immersed in reading prescribed sections of the OSTEP textbook and seminal survey papers on SSD architectures. I meticulously acquainted myself with industry-standard terminologies and concepts like write amplification, garbage collection heuristics, out-of-place updates, and various FTL mapping schemes. This phase was crucial for bridging my computer science software knowledge with hardware realities.
*   **Simulator Setup and Environment Configuration (Weeks 4-6):** Transitioning from theory to practical implementation, I cloned the SimpleSSD-Standalone 2.0 repository from GitHub (SimpleSSD Authors, n.d.). This stage presented significant logistical and technical challenges. I had to resolve complex CMake dependencies, configure secure SSH keys for recursive git submodule initialization, and align GNU compiler flags to generate optimized binaries suitable for heavy simulation. I documented this entire process in a setup log to aid future researchers joining the lab.
*   **Codebase Investigation (Weeks 7-8):** With the simulator successfully compiling and running, I delved into its vast internal C++ architecture. I systematically mapped the execution path of a single I/O request starting from the synthetic workload generator, passing through the Host Interface Layer (HIL), entering the Internal Cache Layer (ICL) which manages the DRAM buffers, and finally descending to the Flash Translation Layer (FTL) and the Physical Abstraction Layer (PAL).
*   **Advanced Literature Review (Weeks 9-10):** Having understood the simulator, I undertook deep, analytical reviews of the core papers authored by my mentors (RASP, CARDR, SrFTL, and FatCBST). I held regular technical discussions and brainstorming sessions with PhD scholar Waqar Hassan Mir. These discussions helped me clarify incredibly complex algorithms, such as the spatial correlation mathematical models used in RASP and the specific decision tree boundaries utilized in CARDR's malware detection module.
*   **Data Analysis and Scoping (Weeks 11-12):** In the final weeks of the internship, I ran extensive, multi-hour simulations using realistic trace workloads (specifically the `io64` traces). I wrote custom scripts to parse the verbose simulation outputs, evaluating crucial metrics like cache hit rates, CPU busy ticks across internal ARM controller cores, and the micro-joule energy consumption of specific flash operations. 

## 4. Project Outcomes/Findings from the Assigned Work

A major, tangible deliverable of this internship was establishing a fully reproducible, robust simulation environment on my local Linux workstation. I successfully built the SimpleSSD-Standalone framework (Gouk et al., 2018), independently compiling both the `libsimplessd.a` and `libmcpat.a` static libraries. Furthermore, I developed automated bash scripts (`run_sim.sh`) to streamline workload execution, pipelining outputs for easier parsing.

Analyzing the raw output from the simulator (`io64.txt`) provided a concrete, empirical understanding of SSD internal mechanics that textbooks cannot fully convey. During a standard simulation tick span of 1,051,107,540,367 picoseconds (roughly 1.05 seconds of simulated time), the following critical performance metrics were observed:

*   **I/O and Caching Metrics:** The simulated host issued exactly 65,536 write requests, transferring a total of 256 MB of data. The Internal Cache Layer (DRAM) absorbed this massive influx of traffic incredibly efficiently, with 64,595 of the requests served directly to the cache without touching the flash. This translates to an outstanding ~98.5% cache hit rate for writes, heavily mitigating the immediate need to access the painfully slow NAND flash cells and saving the drive from immense wear.
*   **Energy and Power Consumption:** The energy metrics highlighted the massive disparity between volatile and non-volatile memory. The embedded DRAM cache consumed 35.51 mJ of energy at an average power of 33.38 mW. In stark contrast, the NAND flash (PAL layer) consumed 4.50 J of energy to perform 60,224 physical program (write) operations, running at an average power of ~4.28 W. This stark contrast quantitatively demonstrated exactly why advanced cache management mechanisms like RASP are so vital; flashing data to NAND is orders of magnitude more power-intensive and slower than caching it in DRAM.
*   **Internal CPU Utilization:** The SSD's internal multi-core ARM processor showed highly distinct load distributions. The ICL core and FTL core experienced the highest utilization, clocking in at 178 billion and 184 billion busy ticks respectively. This empirically confirmed our theoretical understanding that dynamic address translation (L2P) and DRAM cache management constitute the absolute bulk of the firmware's computational overhead, whereas the Host Interface Layer (HIL) only required around 97 billion busy ticks.

## 5. Personal Learning/Reflections

The technical density of this internship resulted in a steep but exceptionally rewarding learning curve. Coming into the program with limited exposure to low-level computer architecture, I was forced out of my comfort zone. I learned to independently navigate massive, complex C++ codebases, utilize advanced Linux development tools like CMake and GNU Make, and extract actionable, statistical data from highly verbose simulation logs. 

Before this internship, I viewed storage simply as a "black box" block device where files were magically saved and retrieved by the operating system. Now, I possess a deep understanding of the intricate orchestration of flash translation, wear leveling, and advanced caching algorithms that occur within milliseconds inside the SSD's embedded processor. I also learned how hardware and firmware can be ingeniously adapted to serve cybersecurity purposes—such as using cache evictions and latency spikes as a heuristic for zero-day ransomware detection.

Furthermore, this internship perfectly bridged my theoretical undergraduate coursework with practical, cutting-edge systems engineering. The algorithms discussed theoretically in my data structures classes were visibly applied in papers like FatCBST to solve real-world concurrent bottlenecks. Experiencing the daily operations of the Computer Architecture and Systems Research Lab has deeply inspired me. I have realized that my true passion lies at the intersection of low-level systems architecture and hardware security, cementing my commitment to pursuing higher academic studies and eventually a PhD in Computer Systems.

## 6. Limitations of the Internship

While the internship was highly successful and immensely educational, it was not without its limitations. Foremost was the inherent complexity of the SSD firmware architecture. Comprehending the full, holistic scope of a production-grade FTL required significant time, which constrained the amount of original, modified C++ code I could contribute directly to the simulator within a short 12-week timeframe. 

Additionally, the entirety of the research was conducted via software simulation (Gouk et al., 2018). While tools like SimpleSSD are highly accurate and industry-standard, the lack of access to physical open-channel SSD hardware or programmable FPGAs meant that certain real-world physical anomalies—like unpredictable thermal throttling, electrical latency spikes, and physical cell degradation—could not be observed firsthand. Lastly, adjusting to the intricate environment configurations required for C++ academic simulators on Linux occupied a larger portion of the initial weeks than initially anticipated.

## References

Alapati, P., Tavva, V. K., & Mutyam, M. (2017). FatCBST: Concurrent binary search tree with fatnodes. *2017 IEEE 19th International Conference on High Performance Computing and Communications; IEEE 15th International Conference on Smart City; IEEE 3rd International Conference on Data Science and Systems (HPCC/SmartCity/DSS)*, 356–363. https://doi.org/10.1109/HPCC-SmartCity-DSS.2017.47

Arpaci-Dusseau, R. H., & Arpaci-Dusseau, A. C. (2018). *Operating systems: Three easy pieces*. Arpaci-Dusseau Books.

Gouk, D., Kwon, M., Zhang, J., Koh, S., Choi, W., Kim, N. S., Kandemir, M., & Jung, M. (2018). Amber: Enabling precise full-system simulation with detailed modeling of all ssd resources. *51st Annual IEEE/ACM International Symposium on Microarchitecture (MICRO)*, 469–481. https://doi.org/10.1109/MICRO.2018.00045

Mir, W. H., Goel, N., & Tavva, V. K. (2024). CARDR: DRAM cache assisted ransomware detection and recovery in SSDs. *The International Symposium on Memory Systems (MEMSYS '24)*, 104–115. https://doi.org/10.1145/3695794.3695804

Mir, W. H., Rathi, A., Tavva, V. K., & Goel, N. (2026). RASP: Region-aware single use page predictor for SSD workloads. *IEEE Embedded Systems Letters*, 1–4. https://doi.org/10.1109/LES.2026.3672700

SimpleSSD Authors. (n.d.). *SimpleSSD-Standalone* [Computer software]. GitHub. https://github.com/SimpleSSD/SimpleSSD-Standalone

Zhu, W., Hernandez, G., Garcia, W., Tian, D. J., Rampazzi, S., & Butler, K. R. B. (2025). SrFTL: Leveraging storage semantics for effective ransomware defense in flash-based SSDs. *ACM Transactions on Storage*, 21(4), Article 29. https://doi.org/10.1145/3767322

Zhu, W., Wang, Y., & Zhang, T. (2020). A comprehensive survey of issues in solid state drives. *IEEE Access*, 8, 12433–12450.

## Appendix

**Appendix A: SimpleSSD Simulator Setup Log Excerpt**
```bash
# Installing required system dependencies
sudo apt update
sudo apt-get install cmake git

# Cloning and building the SimpleSSD framework
git clone https://github.com/SimpleSSD/SimpleSSD-Standalone.git
cd Simplessd-Standalone/
git submodule update --init --recursive
cmake -DDEBUG_BUILD=off
make -j 8

# Running the full-system simulator with sample configuration
./simplessd-standalone ./config/sample.cfg ./simplessd/config/sample.cfg ./result >> outputs/my.txt
```
