#!/usr/bin/env bash
# Puts the Windows engine into a built app: WineCore.framework (build-wine-ios.sh) into Frameworks/,
# and Madeira's bundle resources at the bundle's root, where its bridges and Wine's ntdll look for them
# (the main executable's folder): the DLL farms, NLS files, the prefix template, the CA list, the D3D12
# shader converter, and the licence texts. Signed later with the rest of the app.
# Usage: embed-wine.sh <path/to/App.app>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP="$1"
M="$ROOT/native/third_party/Madeira/app/Madeira"
FW="$ROOT/native/wine/out/WineCore.framework"

[ -f "$FW/WineCore" ] || { echo "no $FW (run build-wine-ios.sh first)" >&2; exit 1; }
mkdir -p "$APP/Frameworks"
rm -rf "$APP/Frameworks/WineCore.framework"
cp -R "$FW" "$APP/Frameworks/"

# Wine Mono (downloaded on first use in Madeira) and the Microsoft VC++ runtime (not redistributed)
# are not included, as in Madeira's release builds.
for item in arm64ec-windows aarch64-windows i386-windows nls d3d12 prefix-template.tar.gz cacert.pem; do
    rm -rf "${APP:?}/$item"
    cp -R "$M/$item" "$APP/"
done
# Code pages Madeira does not bundle (native/wine/nls/README.md): Japanese, Chinese, Korean, Cyrillic, ...
cp "$ROOT"/native/wine/nls/*.nls "$APP/nls/"
mkdir -p "$APP/Madeira-licenses"
cp -R "$M/legal" "$M/licenses" "$APP/Madeira-licenses/"
cp "$ROOT/native/third_party/Madeira/LICENSE" "$ROOT/native/third_party/Madeira/LICENSE-EXCEPTION.md" \
   "$ROOT/native/third_party/Madeira/THIRD-PARTY-NOTICES.md" "$APP/Madeira-licenses/"
du -sh "$APP/Frameworks/WineCore.framework" "$APP"/{arm64ec-windows,aarch64-windows,nls,d3d12} "$APP"
