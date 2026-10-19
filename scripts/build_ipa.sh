#!/usr/bin/env bash
# Build an unsigned Gemsloot IPA (macOS + Xcode required).
# Primary path: GitHub Actions (.github/workflows/build-ipa.yml).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() {
  echo "error: $*" >&2
  exit 1
}

if ! command -v xcodegen >/dev/null 2>&1; then
  die "xcodegen not found.
Install on macOS:  brew install xcodegen
CI installs it automatically. Local unsigned builds require macOS + Xcode."
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  die "xcodebuild not found.
Unsigned IPA builds need macOS with Xcode Command Line Tools.
Use the GitHub Actions workflow (macos-latest) as the primary build path."
fi

if ! command -v zip >/dev/null 2>&1; then
  die "zip not found"
fi

echo "==> Generating Xcode project from project.yml"
xcodegen generate --spec project.yml

echo "==> Cleaning previous build outputs"
rm -rf build/DerivedData build/Payload build/Gemsloot-iOS.ipa
mkdir -p build

echo "==> xcodebuild Release (unsigned, generic iOS)"
xcodebuild \
  -project Gemsloot.xcodeproj \
  -scheme Gemsloot \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  AD_HOC_CODE_SIGNING_ALLOWED=YES \
  build

PRODUCTS_DIR="build/DerivedData/Build/Products/Release-iphoneos"
APP_PATH="$(find "$PRODUCTS_DIR" -maxdepth 1 -name '*.app' -print 2>/dev/null | head -n 1 || true)"

if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  die "No .app found under ${PRODUCTS_DIR}
Check xcodebuild logs above."
fi

# Confirm AppIcon asset catalog compiled into the app (Assets.car).
if [[ ! -f "${APP_PATH}/Assets.car" ]]; then
  die "Assets.car missing from ${APP_PATH} — AppIcon catalog may not be linked (check ASSETCATALOG_COMPILER_APPICON_NAME / Assets.xcassets)."
fi
echo "==> App icon assets present (Assets.car $(wc -c < "${APP_PATH}/Assets.car") bytes)"

echo "==> Packaging ${APP_PATH} → build/Gemsloot-iOS.ipa"
rm -rf build/Payload
mkdir -p build/Payload
cp -R "${APP_PATH}" build/Payload/

# Strip quarantine / extended attributes that can break sideload tools.
if command -v xattr >/dev/null 2>&1; then
  xattr -cr build/Payload || true
fi

(
  cd build
  rm -f Gemsloot-iOS.ipa
  zip -qry Gemsloot-iOS.ipa Payload
)

IPA_PATH="${ROOT}/build/Gemsloot-iOS.ipa"
[[ -f "${IPA_PATH}" ]] || die "IPA was not created at ${IPA_PATH}"

echo "==> Done: ${IPA_PATH}"
ls -lh "${IPA_PATH}"
