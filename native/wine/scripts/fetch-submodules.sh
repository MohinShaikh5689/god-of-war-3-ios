#!/usr/bin/env bash
# The submodules the Wine engine's iOS build needs (shallow): Madeira and its FEX, Wine and DXMT forks.
# madeira-dock (the Steam client launcher) is not used. FEX's test-binary repositories are large and
# not needed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
git submodule update --init --depth 1 native/third_party/Madeira
cd native/third_party/Madeira
git submodule update --init --depth 1 FEX wine dxmt
git -C dxmt submodule update --init --depth 1 include/native/directx external/nvapi
git -C FEX submodule update --init --depth 1 External/fmt External/xxhash External/range-v3 \
  External/unordered_dense External/vixl External/jemalloc_glibc External/rpmalloc Source/Common/cpp-optparse
