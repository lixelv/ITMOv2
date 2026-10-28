import Foundation

extension SSHConfigStore {
    public func add(_ fields: ServerFields) async throws { throw ServerStoreError.readOnly(fields.name) }
    public func update(_ name: String, to fields: ServerFields) async throws { throw ServerStoreError.readOnly(name) }
    public func remove(_ name: String) async throws { throw ServerStoreError.readOnly(name) }
}
