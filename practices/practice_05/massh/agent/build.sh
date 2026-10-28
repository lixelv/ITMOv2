#!/bin/sh
# Static Agent binaries for every supported Server architecture, into dist/.
set -eu
cd "$(dirname "$0")"
version=$(cat VERSION)
mkdir -p dist
for arch in amd64 arm64; do
	CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath \
		-ldflags "-s -w -X main.version=$version" \
		-o "dist/massh-agent-linux-$arch" ./cmd/massh-agent
done
cp installer/massh-agent-install.sh dist/
echo "built massh-agent $version for linux/amd64 and linux/arm64 in $(pwd)/dist"
