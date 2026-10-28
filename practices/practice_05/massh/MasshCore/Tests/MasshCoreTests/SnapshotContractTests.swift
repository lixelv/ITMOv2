import Foundation
import Testing
import MasshCore

/// Shared reference Snapshot JSON, produced by the Agent's tests as well.
func contractFixture(_ name: String) throws -> Data {
    let url = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "../../../contract/fixtures/\(name)")
        .standardized
    return try Data(contentsOf: url)
}

@Suite("Snapshot contract")
struct SnapshotContractTests {
    @Test func decodesNormalSnapshot() throws {
        let message = try SnapshotMessage.decode(contractFixture("normal.json"))
        guard case .snapshot(let snapshot) = message else {
            Issue.record("expected a snapshot, got \(message)")
            return
        }
        #expect(snapshot.formatVersion == 2)
        #expect(snapshot.agentVersion == "0.1.0")
        #expect(snapshot.time == Date(timeIntervalSince1970: 1_793_188_800))
        #expect(snapshot.overview.os == "Ubuntu 24.04.1 LTS")
        #expect(snapshot.overview.loadAverage == [0.42, 0.35, 0.3])
        #expect(snapshot.overview.cpu.perCorePercent == [30, 17])
        #expect(snapshot.overview.swap == .init(totalBytes: 2_147_479_552, usedBytes: 0))
        #expect(snapshot.overview.disks.map(\.mountPoint) == ["/", "/boot"])
        #expect(snapshot.overview.network.rxBytesPerSecond == 15360)
        #expect(snapshot.ports.map(\.owner) == [
            .process(pid: 812, name: "sshd"),
            .container(name: "web"),
            nil,
        ])
        #expect(snapshot.processes.map(\.name) == ["systemd", "sshd", "postgres"])
        #expect(snapshot.processes[2].cpuPercent == 12.25)
        guard case .available(let containers) = snapshot.docker else {
            Issue.record("expected Docker to be available")
            return
        }
        #expect(containers.first?.memoryLimitBytes == 536_870_912)
        #expect(containers.first?.ports == ["0.0.0.0:8080->80/tcp"])
    }

    @Test func decodesSnapshotWithoutDocker() throws {
        let snapshot = try #require(SnapshotMessage.decode(contractFixture("no-docker.json")).snapshot)
        #expect(snapshot.docker == .notInstalled)
        #expect(snapshot.ports.count == 2)
    }

    @Test func decodesSnapshotWithEmptyLists() throws {
        let snapshot = try #require(SnapshotMessage.decode(contractFixture("empty.json")).snapshot)
        #expect(snapshot.overview.disks.isEmpty)
        #expect(snapshot.ports.isEmpty)
        #expect(snapshot.processes.isEmpty)
        #expect(snapshot.docker == .available([]))
    }

    @Test func decodesPreviousFormatVersion() throws {
        let snapshot = try #require(SnapshotMessage.decode(contractFixture("v1.json")).snapshot)
        #expect(snapshot.formatVersion == 1)
        #expect(snapshot.overview.swap == nil)
        #expect(snapshot.overview.cpu.perCorePercent.isEmpty)
        guard case .available(let containers) = snapshot.docker else {
            Issue.record("expected Docker to be available")
            return
        }
        #expect(containers.first?.memoryLimitBytes == nil)
        #expect(snapshot.processes.count == 3)
    }

    @Test func recognisesUnknownNewerFormat() throws {
        let message = try SnapshotMessage.decode(contractFixture("future.json"))
        #expect(message == .unsupportedFormat(version: 99, agentVersion: "9.0.0"))
    }

    @Test func rejectsGarbage() {
        #expect(throws: (any Error).self) { try SnapshotMessage.decode(Data("not json".utf8)) }
    }
}
