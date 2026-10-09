import Foundation

/// Registrations are generation-scoped so completion cannot remove a reused request ID.
package actor AIRequestRegistry {
    private struct Entry {
        let generation: UUID
        var cancel: (@Sendable () -> Void)?
    }
    package init() {}

    private var entries: [UUID: Entry] = [:]

    package func begin(_ id: UUID) throws -> UUID {
        guard entries[id] == nil else {
            throw AIProviderError.invalidConfiguration(detail: "An operation with this request ID is already active.")
        }
        let generation = UUID()
        entries[id] = Entry(generation: generation)
        return generation
    }

    package func register(_ id: UUID, generation: UUID, cancel: @escaping @Sendable () -> Void) {
        guard entries[id]?.generation == generation else {
            cancel()
            return
        }
        entries[id]?.cancel = cancel
    }

    package func finish(_ id: UUID, generation: UUID) {
        guard entries[id]?.generation == generation else { return }
        entries[id] = nil
    }

    package func cancel(_ id: UUID) {
        let entry = entries.removeValue(forKey: id)
        entry?.cancel?()
    }
}
