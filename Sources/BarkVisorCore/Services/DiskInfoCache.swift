import Foundation
import GRDB

public actor DiskInfoCache {
    public struct CachedDiskInfo: Sendable {
        public let virtualSize: Int64
        public let actualSize: Int64

        public init(virtualSize: Int64, actualSize: Int64) {
            self.virtualSize = virtualSize
            self.actualSize = actualSize
        }
    }

    private var cache: [String: CachedDiskInfo] = [:]
    private var refreshTask: Task<Void, Never>?
    private let dbPool: DatabasePool

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    public func start() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await refreshAll()
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func get(_ diskID: String) -> CachedDiskInfo? {
        cache[diskID]
    }

    public func invalidate(_ diskID: String) {
        cache.removeValue(forKey: diskID)
    }

    private func refreshAll() async {
        do {
            let disks = try await dbPool.read { db in
                try Disk.fetchAll(db)
            }
            // Capture disk info needed for detached tasks (to avoid Sendable issues)
            struct DiskRef: Sendable {
                let id: String
                let path: String
            }
            let diskRefs = disks.map { DiskRef(id: $0.id, path: $0.path) }

            // Run blocking qemu-img calls off the cooperative thread pool, limited to 4 concurrent
            let maxConcurrent = 4
            let results: [(String, CachedDiskInfo)] = await withTaskGroup(
                of: (String, CachedDiskInfo)?.self,
            ) { group in
                var index = 0
                var collected: [(String, CachedDiskInfo)] = []

                for diskRef in diskRefs {
                    if index >= maxConcurrent {
                        // Wait for one to finish before adding more
                        if let result = await group.next(), let r = result {
                            collected.append(r)
                        }
                    }
                    group.addTask {
                        guard FileManager.default.fileExists(atPath: diskRef.path) else { return nil }
                        let detached = Task.detached(priority: .utility) {
                            try DiskService.getImageInfo(path: diskRef.path)
                        }
                        if let info = try? await detached.value {
                            return (
                                diskRef.id,
                                CachedDiskInfo(virtualSize: info.virtualSize, actualSize: info.actualSize),
                            )
                        }
                        return nil
                    }
                    index += 1
                }
                for await result in group {
                    if let r = result { collected.append(r) }
                }
                return collected
            }
            // Build fresh cache, discarding stale entries for deleted disks
            var newCache: [String: CachedDiskInfo] = [:]
            for (id, info) in results {
                newCache[id] = info
            }
            cache = newCache
        } catch {
            Log.server.error("DiskInfoCache refresh failed: \(error)")
        }
    }
}
