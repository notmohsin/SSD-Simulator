# SimpleSSD

A flexible, open-source SSD simulator for research, education, and full-system storage evaluation.

SimpleSSD models SSD internals, flash translation layers, caching policies, garbage collection, and host-visible I/O behavior in a configurable C++ framework. It is designed for exploring SSD design trade-offs, evaluating caching and mapping strategies, and running reproducible workloads through a standalone simulation pipeline.

This repository is the standalone build of the SimpleSSD project used for experiment execution, workload sweeps, and analysis workflows.

## Why SimpleSSD?

- Configurable SSD architecture with host, FTL, DRAM, and NAND layers
- Support for simulation-driven evaluation of cache mapping policies and SSD behavior
- Workload sweep tooling for systematic experiment runs
- Research-oriented output logs for subsystem statistics and hit-rate analysis
- Built around a reusable C++ simulation engine with CMake-based builds

## Features

- NVMe-style simulation and configurable SSD stack
- Cached mapping table (CMT) policies and window-fill experimentation
- Random and sequential workload support
- Flexible configuration with sample config files
- Reproducible experiment automation via `run.sh`
- Integration with DRAMPower and McPAT for power and architecture modeling

## Repository layout

- `simplessd/` — core SSD model and subsystem implementation
- `bil/` — block/interface layer logic
- `igl/` — I/O generation and trace-related logic
- `sil/` — simulation interface layer
- `sim/` — simulator engine and runtime logic
- `util/` — helper utilities and converters
- `config/` — sample simulator configuration files
- `tests/` — test programs and validation utilities
- `tutorial/` — usage and methodology notes
- `Presentation/` and `Report/` — project presentation/report materials
- `Traces/` — trace data used for experiments
- `lib/` — third-party or bundled dependencies such as DRAMPower and INI parser
- `run.sh` — build and experiment runner

## Requirements

Before building the project, make sure you have:

- CMake 3.10 or newer
- A modern C++ compiler (GCC/Clang/MSVC supported)
- Git submodules initialized if the bundled dependencies are not already present

Typical Linux prerequisites:

```bash
git submodule update --init --recursive
```

## Quick start

Build the standalone binary:

```bash
cmake -S . -B build
cmake --build build --target simplessd-standalone
```

The project also includes a convenience launcher:

```bash
bash run.sh
```

This performs the initial build bootstrap and then runs the simulator using the default configuration.

## Running experiments

The repository provides a flexible experiment runner in `run.sh`.

### Single run

```bash
bash run.sh
```

This uses the project defaults for workload, capacity, fill ratio, and policy settings.

### Validation / test mode

```bash
TEST_MODE=true bash run.sh
```

This runs a focused validation workflow to check CMT/window-fill behavior.

### Sweep mode

```bash
SWEEP_MODE=true MAX_PARALLEL=4 bash run.sh
```

This launches a parameter sweep across workload and policy combinations and stores output logs in the `outputs/` directory.

### Useful commands

```bash
bash run.sh clean
bash run.sh kill
```

- `clean` removes orphaned temporary simulation directories
- `kill` terminates active simulator processes

## Configuration

Configuration files are stored under:

- `config/`
- `simplessd/config/`

The runner script patches these configuration templates at runtime to explore different SSD settings such as:

- workload type
- I/O size
- block size
- queue depth
- CMT policy
- CMT capacity
- fill ratio
- eviction policy
- window-fill mode

You can tune the defaults directly in `run.sh`.

## Output and analysis

When you run experiments, generated log files are written under `outputs/`.

These outputs include:

- simulation summary
- subsystem-level statistics
- CMT hit-rate metrics
- fill accuracy information
- validation and sweep reports

The repository also includes educational materials in `tutorial/` and supporting documents in `Presentation/` and `Report/`.

## Build architecture

The project uses CMake to compile the SSD model and its dependencies:

- `CMakeLists.txt` assembles the standalone simulator executable
- `simplessd/CMakeLists.txt` builds the main SSD library
- `simplessd/lib/mcpat/CMakeLists.txt` builds the McPAT dependency

The simulation is linked with the bundled SSD core and power-model libraries.

## Licensing

SimpleSSD is released under the GNU General Public License v3.0. See `LICENSE` for details.

## Project references

This project is associated with research and educational work from CAMELab and the SimpleSSD project ecosystem. More information is available at:

- http://camelab.org
- http://simplessd.org

## Contributing

Contributions, issue reports, and improvements are welcome. If you are extending the simulator or adding new experiments, please keep the project’s configuration, build flow, and documentation consistent with the existing structure.

## Summary

SimpleSSD is a practical SSD simulator for understanding storage behavior under realistic workload patterns and policy choices. It is especially useful for exploring cache and mapping strategies, NAND behavior, and SSD performance trade-offs in a controlled and reproducible environment.
