# Build outputs live outside ~/Documents: iCloud xattrs there break codesigning of test bundles.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
BUILD ?= $(HOME)/Library/Caches/massh

.PHONY: test test-core test-agent test-integration agent app

test: test-agent test-core

test-core:
	cd MasshCore && swift test --scratch-path $(BUILD)/MasshCore

test-agent:
	cd agent && go vet ./... && go test ./...

images:
	docker build -q -t massh-test-server:docker --build-arg WITH_DOCKER=1 agent/integration/image
	docker build -q -t massh-test-server:nodocker --build-arg WITH_DOCKER=0 agent/integration/image

# Needs OrbStack (or Docker): Linux test Servers with systemd, sshd and Docker.
test-integration: images agent
	cd agent && go test -tags integration -count=1 -timeout 20m ./integration/...
	cd MasshCore && MASSH_INTEGRATION=1 swift test --scratch-path $(BUILD)/MasshCore

agent:
	cd agent && ./build.sh

app: agent
	cd MasshApp && ./bundle.sh
