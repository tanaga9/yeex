import Foundation
import Testing
@testable import YeeXCore

@Test func largeCatalogUpdatesKeepNeighbors() throws {
    let count = 30_000
    let seed = UUID()
    let catalog = Catalog()
    let folder = URL(fileURLWithPath: "/test", isDirectory: true)
    func record(_ index: Int, timestamp: Int) -> ImageRecord {
        ImageRecord(url: folder.appendingPathComponent(String(format: "%05d.png", index)),
                    modified: Date(timeIntervalSince1970: Double(timestamp)), seed: seed)
    }
    for index in 0..<count { catalog.upsert(record(index, timestamp: index)) }
    for index in stride(from: 0, to: count, by: 3) { catalog.remove(record(index, timestamp: index).id) }
    let updated = record(1, timestamp: count)
    catalog.upsert(updated)
    #expect(catalog.count == 20_000)
    #expect(catalog.first(.mtime) == updated.id)
    #expect(catalog.first(.fname) == record(count - 1, timestamp: count - 1).id)
    for order in BrowseOrder.allCases {
        var next = catalog.first(order)
        var prior: String?
        var visited = Set<String>()
        while let id = next, visited.insert(id).inserted {
            #expect(catalog.neighbor(id, order: order, forward: false, loop: false) == prior)
            prior = id
            next = catalog.neighbor(id, order: order, forward: true, loop: false)
        }
        #expect(next == nil)
        #expect(visited.count == 20_000)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["YEEX_BENCHMARK_FOLDER"] != nil))
func benchmarkFolder() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["YEEX_BENCHMARK_FOLDER"])
    let folder = URL(fileURLWithPath: path, isDirectory: true)
    let clock = ContinuousClock()
    let start = clock.now
    let measurement = ScanMeasurement(start: start)
    _ = try await FolderScanner.scan(folder, seed: UUID()) {
        await measurement.consume($0)
    }
    try await measurement.report(scanComplete: clock.now)
}

private actor ScanMeasurement {
    private let catalog = Catalog()
    private let start: ContinuousClock.Instant
    private var firstDiscovery: ContinuousClock.Instant?
    private var firstImageTask: Task<ContinuousClock.Instant?, Never>?

    init(start: ContinuousClock.Instant) { self.start = start }

    func consume(_ batch: [ImageRecord]) {
        if firstDiscovery == nil, let record = batch.first {
            firstDiscovery = .now
            firstImageTask = Task.detached {
                ImageDecoder.decode(record.url) == nil ? nil : .now
            }
        }
        for record in batch { catalog.upsert(record) }
    }

    func report(scanComplete: ContinuousClock.Instant) async throws {
        let discovery = try #require(firstDiscovery)
        let decode = await firstImageTask?.value
        let pipeline = ImagePipeline()
        var durations: [Double] = []
        var next = catalog.first(.mtime)
        while let id = next, let record = catalog[id], durations.count < 150 {
            let before = ContinuousClock.now
            if await pipeline.image(record) != nil {
                durations.append(seconds(before.duration(to: .now)) * 1000)
            }
            next = catalog.neighbor(id, order: .mtime, forward: true, loop: false)
        }
        let image = try #require(decode)
        let sorted = durations.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
        }
        print(String(format: "YeeX: %d images, discovery %.2f ms, first decode %.2f ms, scan+index %.2f ms, uncached switches %d (p50 %.3f ms, p95 %.3f ms)",
                     catalog.count, seconds(start.duration(to: discovery)) * 1000, seconds(start.duration(to: image)) * 1000,
                     seconds(start.duration(to: scanComplete)) * 1000, durations.count, percentile(0.5), percentile(0.95)))
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
