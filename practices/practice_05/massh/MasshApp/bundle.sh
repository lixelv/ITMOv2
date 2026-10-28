#!/bin/sh
# Builds build/massh.app: release binary, Agent binaries in Resources/agent, ad-hoc signature, no App Sandbox (ADR 0006).
set -eu
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
scratch=${BUILD:-$HOME/Library/Caches/massh}/MasshApp
swift build -c release --scratch-path "$scratch"
bin=$(swift build -c release --scratch-path "$scratch" --show-bin-path)

app=build/massh.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/agent"
cp "$bin/massh" "$app/Contents/MacOS/massh"
for bundle in "$bin"/*.bundle; do [ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"; done
cp ../agent/dist/massh-agent-linux-amd64 ../agent/dist/massh-agent-linux-arm64 ../agent/dist/massh-agent-install.sh \
	"$app/Contents/Resources/agent/"
version=$(cat ../agent/VERSION)
# MasshCore compares installed Agents against its own copy of the version; the two must agree.
grep -q "bundledVersion = \"$version\"" ../MasshCore/Sources/MasshCore/AgentOperations.swift ||
	{ echo "agent/VERSION ($version) differs from AgentRelease.bundledVersion" >&2; exit 1; }
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>massh</string>
	<key>CFBundleIdentifier</key><string>dev.massh.app</string>
	<key>CFBundleName</key><string>massh</string>
	<key>CFBundleDisplayName</key><string>massh</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$version</string>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
# Ad-hoc signature without entitlements: no App Sandbox, so /usr/bin/ssh and ~/.ssh/config are reachable.
codesign --force --deep --sign - "$app"
echo "built $(pwd)/$app"
