#!/bin/bash
# Builds and runs the C++ core unit tests on the Mac (or Linux). Needs only clang++.
set -euo pipefail
cd "$(dirname "$0")/../Core"
make test
