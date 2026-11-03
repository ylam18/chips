#!/bin/sh
# Builds build/UsageBar.app: release binary + Info.plist (no Dock icon), ad-hoc signed.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
bin_dir=$(swift build -c release --show-bin-path)

app=build/UsageBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/UsageBar" "$app/Contents/MacOS/UsageBar"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --sign - --force "$app"

echo "Built $app"
