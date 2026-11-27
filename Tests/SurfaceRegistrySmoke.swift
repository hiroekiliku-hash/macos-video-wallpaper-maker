import Foundation

@main enum SurfaceRegistrySmoke {
    final class Resource { var disposed = false }
    static func main() throws {
        var disposed = 0
        let registry = SurfaceRegistry<Resource>(grace: 0.03, maxIdle: 2, pause: { _ in }, dispose: { value in
            precondition(!value.disposed); value.disposed = true; disposed += 1
        })
        let first = UUID(), second = UUID()
        let original = registry.acquire(id: first, key: "live") { Resource() }
        let shared = registry.acquire(id: second, key: "live") { Resource() }
        precondition(original === shared)
        registry.release(id: first)
        precondition(registry.value(for: second) === original)
        registry.release(id: second)
        let reconnect = UUID()
        precondition(registry.acquire(id: reconnect, key: "live") { Resource() } === original)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(!original.disposed)
        registry.release(id: reconnect)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(original.disposed && registry.count == 0 && registry.requestCount == 0)
        for index in 0..<100 {
            let id = UUID()
            _ = registry.acquire(id: id, key: "preview-\(index)") { Resource() }
            registry.release(id: id)
            precondition(registry.count <= 2 && registry.requestCount == 0)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(registry.count == 0 && disposed == 101)
        print("Shared leases, reconnect grace, 100 retired previews and request cleanup passed")
    }
}
