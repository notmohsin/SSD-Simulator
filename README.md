# SimpleSSD version 2.0
Open-Source Licensed Educational SSD Simulator for High-Performance Storage and Full-System Evaluations

This project is managed by [CAMELab](http://camelab.org).
For more information, please visit [SimpleSSD homepage](http://simplessd.org).

## Running

Run the experiment launcher with `bash run.sh`. On its first normal invocation,
the launcher removes any existing `simplessd-standalone` executable and builds a
fresh binary using the existing CMake build tree. A local marker records the
successful bootstrap so later invocations reuse the binary.

The first run requires CMake, a C++ compiler, and an initialized `simplessd`
source directory. To force another fresh bootstrap, remove
`.run-build-initialized` and run the launcher again. The `clean` command only
removes temporary simulation directories and does not reset the build marker.

## Licenses
SimpleSSD is released under the GPLv3 license. See `LICENSE` file for details.
