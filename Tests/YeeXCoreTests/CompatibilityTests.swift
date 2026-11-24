import Foundation
import ImageIO
import os
import Testing
@testable import YeeXCore

private func fixture(_ name: String) -> URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(name)
}

private func fixturesOracle() throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture("oracle.json"))) as? [String: Any])
}

@Test func metadataMatchesFixtureExpectations() throws {
    let oracle = try fixturesOracle()
    for name in ["metadata-jpeg.webp", "metadata-png.JPG", "metadata-webp.png"] {
        let expected = try #require(oracle[name] as? [String: Any])
        let image = fixture(name)
        let metadata = try ImageMetadata.read(image)
        #expect(metadata.format == expected["format"] as? String)
        #expect(metadata.raw == expected["raw"] as? [String: String])
        let fields = try #require(expected["fields"] as? [String: Any])
        for key in ["generator", "prompt", "negative_prompt", "parameters_raw", "Steps", "Seed"] {
            if let value = fields[key] {
                #expect(metadata.fields[key] == String(describing: value))
            }
        }
        for (key, document) in [("prompt_json", metadata.promptJSON), ("workflow_json", metadata.workflowJSON)] {
            if let expectedJSON = fields[key] as? NSDictionary {
                let document = try #require(document)
                let actual = try JSONSerialization.jsonObject(with: Data(document.utf8)) as? NSDictionary
                #expect(actual == expectedJSON)
            }
        }
        #expect(ImageDecoder.decode(image) != nil)
    }
}

@Test func randomOrderMatchesUUIDv5Fixture() throws {
    let seed = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let expected = try #require(try fixturesOracle()["randomOrder"] as? [String])
    let catalog = Catalog()
    for identity in expected.reversed() {
        catalog.upsert(ImageRecord(url: URL(fileURLWithPath: "/\(identity).png"), modified: .distantPast,
                                   identity: identity, seed: seed))
    }
    var observed: [String] = []
    var next = catalog.first(.random)
    while let id = next {
        observed.append(try #require(catalog[id]?.identity))
        next = catalog.neighbor(id, order: .random, forward: true, loop: false)
    }
    #expect(observed == expected)
}

@Test(arguments: ["jpg", "png", "bmp", "ico", "tga", "tiff", "avif", "pbm", "pgm", "ppm", "webp",
                  "pdf", "svg", "svgz", "wbmp", "xbm", "xpm"])
func formatDecode(ext: String) throws {
    let image = try #require(ImageDecoder.decode(fixture("red.\(ext)")))
    if ["svg", "svgz"].contains(ext) {
        #expect(image.image.width == 8)
        #expect(image.image.height == 12)
    } else if !["pdf", "wbmp", "xpm"].contains(ext) {
        #expect(image.image.width == 32)
        #expect(image.image.height == 32)
    }
}

@Test(arguments: ["gif", "webp"])
func animationFrames(ext: String) throws {
    let url = fixture("two-frame.\(ext)")
    let first = try #require(ImageDecoder.decode(url))
    let second = try #require(ImageDecoder.decode(url, frame: 1))
    #expect(first.frameCount == 2)
    #expect(abs(first.frameDelay - 0.11) < 0.02)
    #expect(abs(second.frameDelay - 0.22) < 0.02)
    #expect(first.loopCount == 0)
    #expect(first.image.dataProvider?.data != second.image.dataProvider?.data)
}

@Test func exifOrientationKeepsTheFullRotatedDimensions() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = try #require(ImageDecoder.decode(fixture("red.svg")))
    let url = directory.appendingPathComponent("rotated.jpg")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, original.image, [kCGImagePropertyOrientation: 6] as CFDictionary)
    try #require(CGImageDestinationFinalize(destination))

    let record = ImageRecord(url: url, modified: .distantPast, seed: UUID())
    let prefetched = try #require(await ImagePipeline().image(record, prefetch: true))
    let decoded = try #require(ImageDecoder.decode(url))
    for image in [prefetched.image, decoded.image] {
        #expect(image.width == original.image.height)
        #expect(image.height == original.image.width)
    }
}

@Test(arguments: ["gif", "webp"])
func playbackRetainsTheOpenImageSource(ext: String) async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("animation.\(ext)")
    try FileManager.default.copyItem(at: fixture("two-frame.\(ext)"), to: url)
    let record = ImageRecord(url: url, modified: .distantPast, seed: UUID())
    let playback = AnimationPlayback(url: url)
    let pipeline = ImagePipeline(byteLimit: 0)
    let first = try #require(await pipeline.image(record, playback: playback))
    try FileManager.default.moveItem(at: url, to: directory.appendingPathComponent("renamed.\(ext)"))
    let second = try #require(await pipeline.image(record, frame: 1, playback: playback))
    #expect(first.image.dataProvider?.data != second.image.dataProvider?.data)
}

@Test func pixelmatorArchiveAndPackage() throws {
    let archived = try #require(ImageDecoder.decode(fixture("archive.pxd")))
    #expect(archived.image.width == 32)
    try withTempDirectory { directory in
        let package = directory.appendingPathComponent("image.pxm", isDirectory: true)
        let quickLook = package.appendingPathComponent("QuickLook", isDirectory: true)
        try FileManager.default.createDirectory(at: quickLook, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture("red.tiff"), to: quickLook.appendingPathComponent("Thumbnail.tiff"))
        #expect(ImageDecoder.decode(package)?.image.height == 32)
    }
}

@Test func transfersPreserveSourceAndResolveCollision() throws {
    try withTempDirectory { directory in
        let output = directory.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let source = directory.appendingPathComponent("image.png")
        let original = Data("source".utf8)
        let other = Data("existing".utf8)
        try original.write(to: source)
        let target = output.appendingPathComponent("image.png")
        try other.write(to: target)
        #expect(throws: TransferError.self) {
            try ImageTransfer.run(source: source, directory: output, mode: .move, collision: .fail)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: target) == other)
        let copy = try ImageTransfer.run(source: source, directory: output, mode: .copy, collision: .keepBoth)
        #expect(copy.lastPathComponent == "image-1.png")
        #expect(try Data(contentsOf: target) == other)
        #expect(try Data(contentsOf: copy) == original)
        let existing = try #require(ImageTransfer.existingDestination(at: target))
        let record = try FolderScanner.record(at: source, seed: UUID())
        let move = try ImageTransfer.run(record: record, directory: output, mode: .move, collision: .replace(existing))
        #expect(move.path == target.path)
        #expect(try Data(contentsOf: target) == original)
        #expect(!ImageTransfer.exists(source))
    }
}

@Test(arguments: [TransferMode.copy, .move])
func transferRejectsAFileReplacedSinceItWasDisplayed(mode: TransferMode) throws {
    try withTempDirectory { directory in
        let source = directory.appendingPathComponent("shown.png")
        let target = directory.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("displayed image".utf8).write(to: source)
        let displayed = try FolderScanner.record(at: source, seed: UUID())
        let replacement = Data("replacement image".utf8)
        try replacement.write(to: source, options: .atomic)

        do {
            _ = try ImageTransfer.run(record: displayed, directory: target, mode: mode, collision: .fail)
            Issue.record("A transfer should reject a replaced source")
        } catch TransferError.sourceChanged {
            #expect(try Data(contentsOf: source) == replacement)
            #expect(!ImageTransfer.exists(target.appendingPathComponent(source.lastPathComponent)))
        }
    }
}

@Test func replacingAnImagePreservesAConflictingFolder() throws {
    try withTempDirectory { directory in
        let source = directory.appendingPathComponent("image.png")
        try Data("image".utf8).write(to: source)
        let output = directory.appendingPathComponent("destination")
        let conflicting = output.appendingPathComponent("image.png")
        try FileManager.default.createDirectory(at: conflicting, withIntermediateDirectories: true)
        let child = conflicting.appendingPathComponent("keep.txt")
        let original = Data("keep".utf8)
        try original.write(to: child)

        let existing = try #require(ImageTransfer.existingDestination(at: conflicting))
        #expect(throws: TransferError.self) {
            try ImageTransfer.run(source: source, directory: output, mode: .move, collision: .replace(existing))
        }
        #expect(try Data(contentsOf: child) == original)
        #expect(ImageTransfer.exists(source))
    }
}

@Test func copyFollowsARelativeSymbolicLinkAndKeepsItsName() throws {
    try withTempDirectory { directory in
        let output = directory.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let original = directory.appendingPathComponent("original.png")
        let link = directory.appendingPathComponent("shown.png")
        let contents = Data("image contents".utf8)
        try contents.write(to: original)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "original.png")

        let result = try ImageTransfer.run(source: link, directory: output, mode: .copy, collision: .fail)
        #expect(result.lastPathComponent == "shown.png")
        #expect(try result.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try Data(contentsOf: result) == contents)
        try FileManager.default.removeItem(at: original)
        #expect(throws: POSIXError.self) {
            try ImageTransfer.run(source: link, directory: output, mode: .copy, collision: .keepBoth)
        }
        #expect(try Data(contentsOf: result) == contents)
    }
}

@Test func crossVolumeMoveLeavesAReplacementSourceAlone() throws {
    try withTempDirectory { directory in
        let original = Data("original".utf8)
        let replacement = Data("replacement".utf8)
        let source = directory.appendingPathComponent("image.png")
        let target = directory.appendingPathComponent("moved.png")
        let trash = directory.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        try original.write(to: source)

        let moved = try ImageTransfer.moveAcrossVolumes(source, target: target, collision: .fail,
                                                        trashDirectory: { trash }) { held, payload in
            try replacement.write(to: source)
            try FileManager.default.copyItem(at: held, to: payload)
        }
        #expect(moved == target)
        #expect(try Data(contentsOf: target) == original)
        #expect(try Data(contentsOf: source) == replacement)
        #expect(try Data(contentsOf: trash.appendingPathComponent(source.lastPathComponent)) == original)
    }
}

@Test func crossVolumeMoveRestoresAnOriginalEditedDuringCopy() throws {
    try withTempDirectory { directory in
        let source = directory.appendingPathComponent("image.png")
        let target = directory.appendingPathComponent("moved.png")
        let before = Data("original".utf8)
        let update = Data("updated".utf8)
        try before.write(to: source)
        let writer = try FileHandle(forWritingTo: source)
        defer { try? writer.close() }

        do {
            _ = try ImageTransfer.moveAcrossVolumes(source, target: target, collision: .fail, copy: { held, payload in
                try FileManager.default.copyItem(at: held, to: payload)
                try writer.seekToEnd()
                try writer.write(contentsOf: update)
            })
            Issue.record("The move should have stopped before publishing a stale copy")
        } catch TransferError.sourceChanged {
            #expect(try Data(contentsOf: source) == before + update)
            #expect(!ImageTransfer.exists(target))
        }
    }
}

@Test(arguments: [false, true])
func crossVolumeMoveRestoresAPackageChangedDuringCopy(addMember: Bool) throws {
    try withTempDirectory { directory in
        let source = directory.appendingPathComponent("package.pxd", isDirectory: true)
        let target = directory.appendingPathComponent("moved.pxd", isDirectory: true)
        let member = "Layers/image-data"
        let file = source.appendingPathComponent(member)
        let before = Data("original".utf8)
        let update = Data("updated".utf8)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try before.write(to: file)
        let writer = try FileHandle(forWritingTo: file)
        defer { try? writer.close() }

        do {
            _ = try ImageTransfer.moveAcrossVolumes(source, target: target, collision: .fail, copy: { held, payload in
                try FileManager.default.copyItem(at: held, to: payload)
                if addMember {
                    try update.write(to: held.appendingPathComponent("Layers/new-layer"))
                } else {
                    try writer.seekToEnd()
                    try writer.write(contentsOf: update)
                }
            })
            Issue.record("The move should have stopped before publishing a stale package")
        } catch TransferError.sourceChanged {
            #expect(!ImageTransfer.exists(target))
            if addMember {
                #expect(try Data(contentsOf: source.appendingPathComponent("Layers/new-layer")) == update)
            } else {
                #expect(try Data(contentsOf: file) == before + update)
            }
        }
    }
}

@Test(arguments: [false, true])
func crossVolumeMoveRetainsLateWritesAfterPublishing(trashAvailable: Bool) throws {
    try withTempDirectory { directory in
        let source = directory.appendingPathComponent("image.png")
        let target = directory.appendingPathComponent("moved.png")
        let trash = directory.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let before = Data("original".utf8)
        let update = Data("updated after publishing".utf8)
        try before.write(to: source)
        let writer = try FileHandle(forWritingTo: source)
        defer { try? writer.close() }

        do {
            let moved = try ImageTransfer.moveAcrossVolumes(source, target: target, collision: .fail,
                                                            trashDirectory: {
                try writer.seekToEnd()
                try writer.write(contentsOf: update)
                guard trashAvailable else { throw CocoaError(.fileWriteNoPermission) }
                return trash
            })
            #expect(trashAvailable)
            #expect(moved == target)
            #expect(try Data(contentsOf: trash.appendingPathComponent(source.lastPathComponent)) == before + update)
        } catch TransferError.partialMove(let destination, let retained, _) {
            #expect(!trashAvailable)
            #expect(destination == target)
            #expect(try Data(contentsOf: retained) == before + update)
        }
        #expect(try Data(contentsOf: target) == before)
        #expect(!ImageTransfer.exists(source))
    }
}

@Test func crossVolumeMoveDoesNotReplaceAChangedDestination() throws {
    try withTempDirectory { directory in
        let source = directory.appendingPathComponent("source.png")
        let target = directory.appendingPathComponent("destination.png")
        let original = Data("source image".utf8)
        let replacement = Data("new destination image".utf8)
        try original.write(to: source)
        try Data("confirmed destination".utf8).write(to: target)
        let expected = try #require(ImageTransfer.existingDestination(at: target))

        do {
            _ = try ImageTransfer.moveAcrossVolumes(source, target: target, collision: .replace(expected), copy: { held, payload in
                try FileManager.default.copyItem(at: held, to: payload)
                try replacement.write(to: target, options: .atomic)
            })
            Issue.record("Replacing a changed destination should have failed")
        } catch TransferError.destinationChanged {
            #expect(try Data(contentsOf: target) == replacement)
            #expect(try Data(contentsOf: source) == original)
        }
    }
}

@Test func failedCrossVolumeMoveReportsTheRetainedOriginal() throws {
    try withTempDirectory { directory in
        let original = Data("original".utf8)
        let replacement = Data("replacement".utf8)
        let source = directory.appendingPathComponent("image.png")
        let target = directory.appendingPathComponent("moved.png")
        try original.write(to: source)

        do {
            _ = try ImageTransfer.moveAcrossVolumes(source, target: target, collision: .fail, copy: { _, _ in
                try replacement.write(to: source)
                throw CocoaError(.fileWriteOutOfSpace)
            })
            Issue.record("The move should have failed")
        } catch TransferError.recoveryRequired(let retained, _) {
            #expect(try Data(contentsOf: retained) == original)
        }
        #expect(try Data(contentsOf: source) == replacement)
        #expect(!ImageTransfer.exists(target))
    }
}

@Test(arguments: [false, true])
func refreshPreventsAnOlderDecodeFromRepopulatingTheCache(invalidateFolder: Bool) async throws {
    let url = fixture("red.png")
    let record = ImageRecord(url: url, modified: .distantPast, seed: UUID())
    let original = try #require(ImageDecoder.decode(url))
    let updated = try #require(ImageDecoder.decode(fixture("red.svg")))
    let started = AsyncStream<Void>.makeStream()
    let resume = DispatchSemaphore(value: 0)
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let pipeline = ImagePipeline { _, _ in
        let first = calls.withLock { count in
            count += 1
            return count == 1
        }
        if first {
            started.continuation.yield(())
            guard resume.wait(timeout: .now() + 5) == .success else { return nil }
            return original
        }
        return updated
    }
    let prefetch = Task { await pipeline.image(record, prefetch: true) }
    var events = started.stream.makeAsyncIterator()
    await events.next()
    if invalidateFolder { await pipeline.invalidateImages(in: url.deletingLastPathComponent()) }
    let refreshed = await pipeline.image(record, refresh: !invalidateFolder)
    resume.signal()
    let prior = await prefetch.value
    let cached = await pipeline.image(record)
    #expect(refreshed?.image.width == updated.image.width)
    #expect(prior?.image.width == original.image.width)
    #expect(cached?.image.width == updated.image.width)
    #expect(calls.withLock { $0 } == 2)
}

@Test func manualReloadInvalidatesEveryCachedImageInTheSelectedFolder() async throws {
    let original = try #require(ImageDecoder.decode(fixture("red.png")))
    let updated = try #require(ImageDecoder.decode(fixture("red.svg")))
    let calls = OSAllocatedUnfairLock(initialState: [URL: Int]())
    let pipeline = ImagePipeline { url, _ in
        calls.withLock { counts in
            counts[url, default: 0] += 1
            return counts[url] == 1 ? original : updated
        }
    }
    let seed = UUID()
    let folder = URL(fileURLWithPath: "/cache-example", isDirectory: true)
    let records = ["first.png", "second.png", "child/third.png"].map {
        ImageRecord(url: folder.appendingPathComponent($0), modified: .distantPast, seed: seed)
    }
    for record in records {
        #expect(await pipeline.image(record)?.image.width == original.image.width)
    }
    await pipeline.invalidateImages(in: folder)
    #expect(await pipeline.image(records[0])?.image.width == updated.image.width)
    #expect(await pipeline.image(records[1])?.image.width == updated.image.width)
    #expect(await pipeline.image(records[2])?.image.width == original.image.width)
}

@Test func prefetchSkipsImagesBeyondItsPixelBudget() async throws {
    let record = ImageRecord(url: fixture("red.png"), modified: .distantPast, seed: UUID())
    let smallBudget = ImagePipeline(byteLimit: 32 * 32 * 4 - 1)
    let matchingBudget = ImagePipeline(byteLimit: 32 * 32 * 4)
    #expect(await smallBudget.image(record, prefetch: true) == nil)
    #expect(await smallBudget.image(record)?.image.width == 32)
    #expect(await matchingBudget.image(record, prefetch: true)?.image.width == 32)
}

@Test func watchEventsDuringScanRequestOneFollowUp() {
    var observer = FolderObservation()
    observer.begin()
    let first = observer.changed()
    let second = observer.changed()
    #expect(!first && !second)
    #expect(!observer.requiresReload)
    let scanAgain = observer.finish(ScanResult(candidateNames: ["a.png"]))
    #expect(scanAgain)
    observer.begin()
    let repeatScan = observer.finish(ScanResult(candidateNames: ["a.png", "b.png"]))
    #expect(!repeatScan)
    #expect(!observer.requiresReload)
    #expect(observer.poll(["a.png", "b.png"]) == .keepPolling)
}

@Test func failedScanWithPendingChangeStillAllowsManualRecovery() {
    var observer = FolderObservation()
    observer.begin()
    let duringScan = observer.changed()
    #expect(!duringScan)
    let scanAgain = observer.finish(nil)
    #expect(!scanAgain)
    #expect(observer.requiresReload)
    let whileReloadRequired = observer.changed()
    #expect(!whileReloadRequired)
    observer.begin()
    _ = observer.finish(nil)
    #expect(observer.requiresReload)
    observer.begin()
    _ = observer.finish(ScanResult(candidateNames: ["a.png", "b.png"]))
    #expect(!observer.requiresReload)
    #expect(observer.poll(["a.png"]) == .scan)
}

@Test func pollRetainsLastSuccessfulBaseline() {
    var observer = FolderObservation()
    observer.begin()
    _ = observer.finish(ScanResult(candidateNames: ["a.png"]))
    #expect(observer.poll(["a.png", "b.png"]) == .scan)
    #expect(observer.poll(["a.png"]) == .keepPolling)
    #expect(observer.poll(["b.png"]) == .scan)
    observer.begin()
    _ = observer.finish(nil)
    #expect(observer.poll(["b.png"]) == .scan)
}

@Test func directoryScanIsIncrementalAndNonRecursive() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let subdir = directory.appendingPathComponent("subdir", isDirectory: true)
    try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: false)
    try Data().write(to: subdir.appendingPathComponent("hidden.png"))
    for file in ["a.png", "b.JPG", "c.TIFF", "ignore.txt"] {
        try Data().write(to: directory.appendingPathComponent(file))
    }
    let broken = directory.appendingPathComponent("broken.png")
    try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: directory.appendingPathComponent("missing"))
    let batches = ScanBatches()
    let result = try await FolderScanner.scan(directory, seed: UUID()) { await batches.append($0) }
    let output = await batches.items
    #expect(output.first?.count == 1)
    #expect(Set(output.flatMap { $0.map(\.name) }) == ["a.png", "b.JPG", "c.TIFF"])
    #expect(result.candidateNames == ["a.png", "b.JPG", "c.TIFF", "broken.png"])
    #expect(try FolderScanner.candidateNames(in: directory) == result.candidateNames)
}

private actor ScanBatches {
    private(set) var items: [[ImageRecord]] = []
    func append(_ batch: [ImageRecord]) { items.append(batch) }
}

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("YeeX-tests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func withTempDirectory(_ work: (URL) throws -> Void) throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try work(directory)
}
