import CryptoKit
import Foundation

public enum BrowseOrder: String, CaseIterable, Sendable {
    case mtime, random, fname

    public func toggled(excluding other: Self) -> Self {
        let orders = Self.allCases
        let next = orders[(orders.firstIndex(of: self)! + 1) % orders.count]
        return next == other ? orders[(orders.firstIndex(of: next)! + 1) % orders.count] : next
    }
}

public struct ImageRecord: Equatable, Sendable {
    public let url: URL
    public let id: String
    public let name: String
    public let modified: Date
    let attributeModified: Date?
    public let size: Int
    public let identity: String
    let randomKey: Data

    public init(url: URL, modified: Date, size: Int = 0, identity: String? = nil,
                attributeModified: Date? = nil, seed: UUID) {
        self.url = url
        id = url.standardizedFileURL.path.decomposedStringWithCanonicalMapping
        name = url.lastPathComponent.decomposedStringWithCanonicalMapping
        self.modified = modified
        self.attributeModified = attributeModified
        self.size = size
        self.identity = identity ?? id
        var hash = Insecure.SHA1()
        withUnsafeBytes(of: seed.uuid) { hash.update(bufferPointer: $0) }
        hash.update(data: Data(self.identity.utf8))
        var bytes = Array(hash.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        randomKey = Data(bytes)
    }
}

/// An AVL tree for updates, with a path dictionary and linked neighbors for navigation.
private final class OrderedPaths {
    private final class Entry {
        let record: ImageRecord
        weak var previous: Entry?
        weak var next: Entry?
        init(_ record: ImageRecord) { self.record = record }
    }

    private final class Node {
        var entry: Entry
        var left: Node?
        var right: Node?
        var height = 1
        init(_ entry: Entry) { self.entry = entry }
    }

    private let order: BrowseOrder
    private var entries: [String: Entry] = [:]
    private var root: Node?
    private var first: Entry?
    private var last: Entry?

    init(_ order: BrowseOrder) { self.order = order }

    var firstID: String? { first?.record.id }

    func neighbor(_ id: String, forward: Bool, loop: Bool) -> String? {
        guard let entry = entries[id] else { return nil }
        let adjacent = forward ? entry.next : entry.previous
        return (adjacent ?? (loop ? (forward ? first : last) : nil))?.record.id
    }

    func insert(_ record: ImageRecord) {
        let entry = Entry(record)
        var node = root
        var before: Entry?
        var after: Entry?
        while let current = node {
            if precedes(record, current.entry.record) {
                after = current.entry
                node = current.left
            } else {
                before = current.entry
                node = current.right
            }
        }
        entry.previous = before
        entry.next = after
        if let before { before.next = entry } else { first = entry }
        if let after { after.previous = entry } else { last = entry }
        entries[record.id] = entry
        root = insert(entry, into: root)
    }

    func remove(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let before = entry.previous { before.next = entry.next } else { first = entry.next }
        if let after = entry.next { after.previous = entry.previous } else { last = entry.previous }
        root = remove(entry.record, from: root)
    }

    private func precedes(_ a: ImageRecord, _ b: ImageRecord) -> Bool {
        switch order {
        case .mtime:
            if a.modified != b.modified { return a.modified > b.modified }
        case .random:
            if a.randomKey != b.randomKey { return a.randomKey.lexicographicallyPrecedes(b.randomKey) }
        case .fname:
            if a.name != b.name { return b.name.utf8.lexicographicallyPrecedes(a.name.utf8) }
        }
        return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
    }

    private func insert(_ entry: Entry, into node: Node?) -> Node {
        guard let node else { return Node(entry) }
        if precedes(entry.record, node.entry.record) {
            node.left = insert(entry, into: node.left)
        } else {
            node.right = insert(entry, into: node.right)
        }
        return balance(node)
    }

    private func remove(_ record: ImageRecord, from node: Node?) -> Node? {
        guard let node else { return nil }
        if record.id == node.entry.record.id {
            guard node.left != nil, var successor = node.right else { return node.left ?? node.right }
            while let left = successor.left { successor = left }
            node.entry = successor.entry
            node.right = remove(successor.entry.record, from: node.right)
        } else if precedes(record, node.entry.record) {
            node.left = remove(record, from: node.left)
        } else {
            node.right = remove(record, from: node.right)
        }
        return balance(node)
    }

    private func updateHeight(_ node: Node) {
        node.height = 1 + max(node.left?.height ?? 0, node.right?.height ?? 0)
    }

    private func tilt(_ node: Node) -> Int {
        (node.left?.height ?? 0) - (node.right?.height ?? 0)
    }

    private func rotateLeft(_ node: Node, pivot: Node) -> Node {
        node.right = pivot.left
        pivot.left = node
        updateHeight(node)
        updateHeight(pivot)
        return pivot
    }

    private func rotateRight(_ node: Node, pivot: Node) -> Node {
        node.left = pivot.right
        pivot.right = node
        updateHeight(node)
        updateHeight(pivot)
        return pivot
    }

    private func balance(_ node: Node) -> Node {
        updateHeight(node)
        if tilt(node) > 1, let left = node.left {
            if tilt(left) < 0, let pivot = left.right { node.left = rotateLeft(left, pivot: pivot) }
            return rotateRight(node, pivot: node.left!)
        }
        if tilt(node) < -1, let right = node.right {
            if tilt(right) > 0, let pivot = right.left { node.right = rotateRight(right, pivot: pivot) }
            return rotateLeft(node, pivot: node.right!)
        }
        return node
    }
}

public final class Catalog {
    private let orders = Dictionary(uniqueKeysWithValues: BrowseOrder.allCases.map { ($0, OrderedPaths($0)) })
    private var entries: [String: ImageRecord] = [:]

    public init() {}
    public var count: Int { entries.count }
    public var ids: Dictionary<String, ImageRecord>.Keys { entries.keys }
    public subscript(id: String) -> ImageRecord? { entries[id] }

    public func upsert(_ record: ImageRecord) {
        guard entries[record.id] != record else { return }
        remove(record.id)
        entries[record.id] = record
        for order in orders.values { order.insert(record) }
    }

    public func remove(_ id: String) {
        guard entries.removeValue(forKey: id) != nil else { return }
        for order in orders.values { order.remove(id) }
    }

    public func first(_ order: BrowseOrder) -> String? { orders[order]?.firstID }

    public func neighbor(_ id: String, order: BrowseOrder, forward: Bool, loop: Bool) -> String? {
        orders[order]?.neighbor(id, forward: forward, loop: loop)
    }
}

public struct ScanResult: Sendable {
    public let candidateNames: Set<String>
}

public enum FolderScanner {
    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .contentModificationDateKey, .attributeModificationDateKey, .fileSizeKey, .fileIdentifierKey
    ]

    public static func scan(
        _ folder: URL, seed: UUID, publish: @Sendable ([ImageRecord]) async -> Void
    ) async throws -> ScanResult {
        var scanError: (any Error)?
        guard let entries = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, error in scanError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: folder]) }
        var names = Set<String>()
        var batch: [ImageRecord] = []
        var published = false
        let clock = ContinuousClock()
        var last = clock.now
        while let url = nextURL(entries) {
            try Task.checkCancellation()
            if ImageFormats.accepts(url) {
                names.insert(url.lastPathComponent.decomposedStringWithCanonicalMapping)
                if let record = try? record(at: url, seed: seed) { batch.append(record) }
            }
            if !batch.isEmpty && (!published || batch.count >= 256 || last.duration(to: clock.now) >= .milliseconds(100)) {
                await publish(batch)
                batch.removeAll(keepingCapacity: true)
                published = true
                last = clock.now
            }
        }
        if !batch.isEmpty { await publish(batch) }
        if let scanError { throw scanError }
        return ScanResult(candidateNames: names)
    }

    private static func nextURL(_ entries: FileManager.DirectoryEnumerator) -> URL? {
        entries.nextObject() as? URL
    }

    public static func record(at url: URL, seed: UUID) throws -> ImageRecord {
        let link = try url.resourceValues(forKeys: keys)
        let target = link.isSymbolicLink == true ? url.resolvingSymlinksInPath() : url
        let values = target == url ? link : try target.resourceValues(forKeys: keys)
        guard values.isRegularFile == true ||
                (values.isDirectory == true && ImageFormats.isPixelmator(url)) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSURLErrorKey: url])
        }
        let identifier = values.fileIdentifier.flatMap { $0 > 0 ? String($0) : nil }
        return ImageRecord(url: url, modified: values.contentModificationDate ?? .distantPast,
                           size: values.fileSize ?? 0, identity: identifier,
                           attributeModified: values.attributeModificationDate, seed: seed)
    }

    public static func candidateNames(in folder: URL) throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        return Set(names.lazy.filter { ImageFormats.accepts(name: $0) }
            .map { $0.decomposedStringWithCanonicalMapping })
    }
}
