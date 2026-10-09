import Foundation
import AIClientKit

/// Registrations are generation-scoped so completion cannot remove a reused request ID.
actor CompatibleRequestRegistry {
    private struct Entry {
        let generation: UUID
        var cancel: (@Sendable () -> Void)?
    }
    private var entries: [UUID: Entry] = [:]

    func begin(_ id: UUID) throws -> UUID {
        guard entries[id] == nil else {
            throw AIProviderError.invalidConfiguration(detail: "An operation with this request ID is already active.")
        }
        let generation = UUID()
        entries[id] = Entry(generation: generation)
        return generation
    }

    func register(_ id: UUID, generation: UUID, cancel: @escaping @Sendable () -> Void) {
        guard entries[id]?.generation == generation else {
            cancel()
            return
        }
        entries[id]?.cancel = cancel
    }

    func finish(_ id: UUID, generation: UUID) {
        guard entries[id]?.generation == generation else { return }
        entries[id] = nil
    }

    func cancel(_ id: UUID) {
        let entry = entries.removeValue(forKey: id)
        entry?.cancel?()
    }
}
