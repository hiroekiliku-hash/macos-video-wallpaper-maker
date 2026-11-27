import Foundation

// Main-queue only. Short reconnects keep the frame; abandoned surfaces have a
// bounded lifetime and count, even across repeated settings previews/displays.
final class SurfaceRegistry<Value> {
    private struct Entry {
        let value: Value
        var users: Set<UUID> = []
        var expiry: DispatchWorkItem?
        var retiredAt: TimeInterval?
    }
    private var entries: [String: Entry] = [:]
    private var ids: [UUID: String] = [:]
    private let grace: TimeInterval
    private let maxIdle: Int
    private let pause: (Value) -> Void
    private let dispose: (Value) -> Void

    init(grace: TimeInterval = 15, maxIdle: Int = 2,
         pause: @escaping (Value) -> Void, dispose: @escaping (Value) -> Void) {
        self.grace = grace; self.maxIdle = maxIdle; self.pause = pause; self.dispose = dispose
    }

    func acquire(id: UUID, key: String, make: () throws -> Value) rethrows -> Value {
        if let previous = ids[id], previous != key { release(id: id) }
        var entry: Entry
        if let existing = entries[key] { entry = existing }
        else { entry = Entry(value: try make()) }
        entry.expiry?.cancel(); entry.expiry = nil; entry.retiredAt = nil
        entry.users.insert(id); entries[key] = entry; ids[id] = key
        return entry.value
    }

    func value(for id: UUID) -> Value? { ids[id].flatMap { entries[$0]?.value } }

    func release(id: UUID) {
        guard let key = ids.removeValue(forKey: id), var entry = entries[key] else { return }
        entry.users.remove(id)
        if entry.users.isEmpty {
            pause(entry.value)
            entry.retiredAt = Date.timeIntervalSinceReferenceDate
            let work = DispatchWorkItem { [weak self] in self?.retire(key) }
            entry.expiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
        }
        entries[key] = entry
        let idle = entries.filter { $0.value.users.isEmpty }.sorted { ($0.value.retiredAt ?? 0) < ($1.value.retiredAt ?? 0) }
        for (key, _) in idle.prefix(max(0, idle.count - maxIdle)) { retire(key) }
    }

    private func retire(_ key: String) {
        guard let entry = entries[key], entry.users.isEmpty else { return }
        entries.removeValue(forKey: key)
        entry.expiry?.cancel()
        dispose(entry.value)
    }

    var count: Int { entries.count }
    var requestCount: Int { ids.count }

    deinit {
        for entry in entries.values { entry.expiry?.cancel(); dispose(entry.value) }
    }
}
