# Build outputs live outside ~/Documents: iCloud xattrs there break codesigning of test bundles.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
BUILD ?= $(HOME)/Library/Caches/massh

.PHONY: test test-core test-agent test-integration agent app

test: test-agent test-core

test-core:
	cd MasshCore && swift test --scratch-path $(BUILD)/MasshCore

test-agent:
	cd agent && go vet ./... && go test ./...

test-integration:
	cd agent && go test -tags integration -count=1 -timeout 20m ./integration/...

agent:
	cd agent && ./build.sh

app: agent
	cd MasshApp && ./bundle.sh
