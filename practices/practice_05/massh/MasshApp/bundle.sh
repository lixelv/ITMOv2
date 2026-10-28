#!/bin/sh
# Builds build/massh.app: release binary, Agent binaries in Resources/agent, ad-hoc signature, no App Sandbox (ADR 0006).
set -eu
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
scratch=${BUILD:-$HOME/Library/Caches/massh}/MasshApp
swift build -c release --scratch-path "$scratch"
bin=$(swift build -c release --scratch-path "$scratch" --show-bin-path)

app=${APP:-build/massh.app}
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
# UI strings (String Catalog) into en.lproj / ru.lproj of the app bundle, where SwiftUI looks them up.
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$app/Contents/Resources" >/dev/null
# English is the source language: an empty en.lproj makes it an explicit localization, not just a fallback.
mkdir -p "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/MasshCore_MasshCore.bundle/Contents/Resources/en.lproj"
# App icon made in Icon Composer: Liquid Glass Assets.car plus a classic .icns.
xcrun actool Resources/AppIcon.icon --compile "$app/Contents/Resources" --platform macosx \
	--minimum-deployment-target 26.0 --app-icon AppIcon \
	--output-partial-info-plist "$scratch/AppIcon-partial.plist" >/dev/null
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>massh</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID:-dev.massh.app}</string>
	<key>CFBundleName</key><string>massh</string>
	<key>CFBundleDisplayName</key><string>massh</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
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
xattr -cr "$app" # Finder/iCloud attributes on resources break codesign
codesign --force --deep --sign - "$app"
echo "built $(pwd)/$app"
