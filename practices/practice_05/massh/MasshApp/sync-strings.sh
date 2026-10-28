#!/bin/sh
# Re-extracts localizable strings from the sources into both String Catalogs (new keys appear without
# translations; removed ones are marked stale). Translate new keys in Xcode or by editing the .xcstrings.
set -eu
cd "$(dirname "$0")"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
build=${BUILD:-$HOME/Library/Caches/massh}
out=$(mktemp -d)
swift build --scratch-path "$build/MasshApp" -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$out" >/dev/null
set --
for source in Sources/MasshUI/*.swift Sources/MasshApp/*.swift; do
	data="$out/$(basename "$source" .swift).stringsdata"
	[ -f "$data" ] && set -- "$@" --stringsdata "$data"
done
xcrun xcstringstool sync Resources/Localizable.xcstrings "$@"
(cd ../MasshCore && swift build --scratch-path "$build/MasshCore" >/dev/null)
xcrun xcstringstool sync ../MasshCore/Sources/MasshCore/Resources/Localizable.xcstrings \
	--stringsdata "$build"/MasshCore/out/Intermediates.noindex/MasshCore.build/Debug/MasshCore-t.build/Objects-normal/arm64/*.stringsdata
rm -rf "$out"
echo "catalogs synced"
