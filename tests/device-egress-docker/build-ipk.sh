#!/usr/bin/env bash
# Assemble the architecture-independent package without an OpenWrt SDK.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
export PACKAGE_SOURCE=${PACKAGE_SOURCE:-$HERE/../../luci-app-openclash}
export PACKAGE_OUTPUT=${PACKAGE_OUTPUT:-$HERE/.cache/feature.ipk}
export PACKAGE_MAKE=${PACKAGE_MAKE:-$(command -v gmake || command -v make)}
python3 "$HERE/build_ipk.py"
