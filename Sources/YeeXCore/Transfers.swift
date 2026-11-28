import CryptoKit
import Darwin
import Foundation

public enum TransferMode: String, Sendable {
    case copy, move
}

public enum CollisionChoice: Equatable, Sendable {
    case fail, keepBoth
    case replace(ExistingDestination)
}

public enum TransferCollision: Equatable, Sendable {
    case none
    case existing(ExistingDestination)
    case identical(sourceTrashed: Bool)
}

public struct ExistingDestination: Equatable, Sendable {
    private let device: dev_t
    private let inode: ino_t
    fileprivate let size: off_t
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changeSeconds: Int
    private let changeNanoseconds: Int
    private let kind: mode_t

    public var isDirectory: Bool { kind == S_IFDIR }
    fileprivate var isRegularFile: Bool { kind == S_IFREG }

    fileprivate init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changeSeconds = info.st_ctimespec.tv_sec
        changeNanoseconds = info.st_ctimespec.tv_nsec
        kind = info.st_mode & S_IFMT
    }

    // A rename can change ctime even when the entry and its contents are unchanged.
    fileprivate func matchesRenamedEntry(_ other: Self?) -> Bool {
        guard let other else { return false }
        return device == other.device && inode == other.inode && size == other.size && kind == other.kind &&
            modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
    }
}

public enum TransferError: LocalizedError {
    case sameFile, sourceChanged, destinationExists, destinationChanged, directoryCollision
    case trashLocationUnavailable
    case recoveryRequired(original: URL, error: any Error)
    case partialMove(destination: URL, original: URL, error: any Error)
    case replacementRecoveryRequired(retained: URL, error: any Error)

    public var errorDescription: String? {
        switch self {
        case .sameFile: "The source and destination are the same file."
        case .sourceChanged: "The selected file has changed on disk. Reload the folder before retrying."
        case .destinationExists: "A file already exists at the destination."
        case .destinationChanged: "The destination changed during the transfer. No file was overwritten."
        case .directoryCollision: "Replacing a folder or package is disabled. Choose Keep Both."
        case .trashLocationUnavailable: "macOS did not report where it put the source file. Check the Trash."
        case .recoveryRequired(let original, let error):
            "Move failed. The original is still at \(original.path): \(error.localizedDescription)"
        case .partialMove(let target, let original, let error):
            "Saved a copy at \(target.path). Remaining source data is at \(original.path): \(error.localizedDescription)"
        case .replacementRecoveryRequired(let retained, let error):
            "A destination file was retained at \(retained.path): \(error.localizedDescription)"
        }
    }
}

public enum ImageTransfer {
    public static func exists(_ url: URL) -> Bool {
        existingDestination(at: url) != nil
    }

    public static func existingDestination(at url: URL) -> ExistingDestination? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? ExistingDestination(info) : nil
    }

    public static func resolveCollision(record: ImageRecord, directory: URL, mode: TransferMode) throws -> TransferCollision {
        try resolveCollision(record: record, directory: directory, mode: mode) { url in
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            guard let trashed else { throw TransferError.trashLocationUnavailable }
            return trashed as URL
        }
    }

    static func resolveCollision(record: ImageRecord, directory: URL, mode: TransferMode,
                                 trash: (URL) throws -> URL) throws -> TransferCollision {
        let source = record.url
        let target = directory.appendingPathComponent(source.lastPathComponent)
        guard let existing = existingDestination(at: target) else { return .none }
        if mode == .copy, !existing.isRegularFile { return .existing(existing) }
        let sourceEntry = existingDestination(at: source)
        let sourceVersion = regularFileVersion(at: source)
        guard matchesDisplayedRecord(record) else { throw TransferError.sourceChanged }
        guard let sourceEntry, let sourceVersion,
              let targetVersion = regularFileVersion(at: target),
              sourceVersion.size == targetVersion.size,
              let sourceName = try? URL(fileURLWithPath: source.path).resourceValues(forKeys: [.nameKey]).name,
              let targetName = try? target.resourceValues(forKeys: [.nameKey]).name,
              sourceName == targetName,
              let sourceHash = try? digest(at: source, version: sourceVersion),
              let targetHash = try? digest(at: target, version: targetVersion),
              sourceHash == targetHash,
              regularFileVersion(at: source) == sourceVersion,
              regularFileVersion(at: target) == targetVersion,
              existingDestination(at: source) == sourceEntry,
              existingDestination(at: target) == existing else {
            return existingDestination(at: target).map(TransferCollision.existing) ?? .none
        }

        // Only discard distinct regular entries. A link may depend on the source pathname.
        guard mode == .move, sourceVersion != targetVersion,
              sourceEntry == sourceVersion, existing == targetVersion else {
            return .identical(sourceTrashed: false)
        }
        guard record.attributeModified != nil else { return .existing(existing) }
        try trashDuplicate(source, target: target, sourceVersion: sourceVersion, targetVersion: targetVersion,
                           expectedHash: sourceHash, trash: trash)
        return .identical(sourceTrashed: true)
    }

    private static func regularFileVersion(at url: URL) -> ExistingDestination? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let version = ExistingDestination(info)
        return version.isRegularFile ? version : nil
    }

    private static func digest(at url: URL, version: ExistingDestination) throws -> SHA256.Digest {
        // Nonblocking open also handles a path that has just been replaced by a FIFO.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix(errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, ExistingDestination(info) == version else { throw TransferError.sourceChanged }

        var hash = SHA256()
        var remaining = version.size
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))), !chunk.isEmpty else {
                throw TransferError.sourceChanged
            }
            hash.update(data: chunk)
            remaining -= off_t(chunk.count)
        }
        return hash.finalize()
    }

    private static func trashDuplicate(_ source: URL, target: URL, sourceVersion: ExistingDestination,
                                       targetVersion: ExistingDestination, expectedHash: SHA256.Digest,
                                       trash: (URL) throws -> URL) throws {
        let holding = try temporaryDirectory(in: source.deletingLastPathComponent(), prefix: "YeeX Move Recovery ")
        defer { _ = rmdir(holding.path) }
        let held = holding.appendingPathComponent(source.lastPathComponent)
        guard existingDestination(at: target) == targetVersion else { throw TransferError.destinationChanged }
        guard existingDestination(at: source) == sourceVersion else { throw TransferError.sourceChanged }
        guard renamex_np(source.path, held.path, UInt32(RENAME_EXCL)) == 0 else { throw posix(errno) }

        let trashed: URL
        do {
            guard let heldVersion = existingDestination(at: held), sourceVersion.matchesRenamedEntry(heldVersion),
                  try digest(at: held, version: heldVersion) == expectedHash,
                  existingDestination(at: held) == heldVersion else { throw TransferError.sourceChanged }
            guard existingDestination(at: target) == targetVersion else { throw TransferError.destinationChanged }
            trashed = try trash(held)
        } catch {
            if !exists(held) { throw error }
            try restoreSource(held, to: source, after: error)
        }
        do {
            guard sourceVersion.matchesRenamedEntry(existingDestination(at: trashed)) else { throw TransferError.sourceChanged }
            guard existingDestination(at: target) == targetVersion else { throw TransferError.destinationChanged }
        } catch {
            try restoreSource(trashed, to: source, after: error)
        }
    }

    private static func matchesDisplayedRecord(_ selected: ImageRecord) -> Bool {
        let freshURL = URL(fileURLWithPath: selected.url.path)
        guard let actual = try? FolderScanner.record(at: freshURL, seed: UUID()) else { return false }
        return actual.identity == selected.identity && actual.size == selected.size && actual.modified == selected.modified &&
            (selected.attributeModified == nil || actual.attributeModified == selected.attributeModified)
    }

    static func run(source: URL, directory: URL, mode: TransferMode, collision: CollisionChoice) throws -> URL {
        try run(source: source, directory: directory, mode: mode, collision: collision, selected: nil)
    }

    public static func run(record: ImageRecord, directory: URL, mode: TransferMode, collision: CollisionChoice) throws -> URL {
        try run(source: record.url, directory: directory, mode: mode, collision: collision, selected: record)
    }

    private static func run(source: URL, directory: URL, mode: TransferMode, collision: CollisionChoice,
                            selected: ImageRecord?) throws -> URL {
        let selectedEntry = existingDestination(at: source)
        let target = directory.appendingPathComponent(source.lastPathComponent)
        let resolvedSource = source.resolvingSymlinksInPath()
        let selectedContents = existingDestination(at: resolvedSource)
        if let selected {
            guard selectedEntry != nil, selectedContents != nil,
                  matchesDisplayedRecord(selected),
                  existingDestination(at: source) == selectedEntry,
                  existingDestination(at: resolvedSource) == selectedContents else {
                throw TransferError.sourceChanged
            }
        }
        let samePath = resolvedSource == target.resolvingSymlinksInPath()
        var sourceInfo = stat()
        var targetInfo = stat()
        let sameInode = stat(source.path, &sourceInfo) == 0 && stat(target.path, &targetInfo) == 0 &&
            sourceInfo.st_ino == targetInfo.st_ino && sourceInfo.st_dev == targetInfo.st_dev
        if (samePath || sameInode) && collision != .keepBoth { throw TransferError.sameFile }
        if collision == .fail && exists(target) { throw TransferError.destinationExists }

        if mode == .copy {
            guard stat(resolvedSource.path, &sourceInfo) == 0 else { throw posix(errno) }
            return try publishCopy(resolvedSource, target: target, collision: collision) { input, payload in
                if selected != nil, existingDestination(at: input) != selectedContents {
                    throw TransferError.sourceChanged
                }
                try FileManager.default.copyItem(at: input, to: payload)
                if selected != nil, existingDestination(at: input) != selectedContents {
                    throw TransferError.sourceChanged
                }
            }
        }

        if selected != nil, let selectedEntry {
            return try moveHeldSource(source, target: target, collision: collision,
                                      expected: selectedEntry, tryRename: true,
                                      trashDirectory: userTrash, copy: FileManager.default.copyItem)
        }

        do {
            return try publish(source, target: target, collision: collision)
        } catch let error as POSIXError where error.code == .EXDEV {
            return try moveAcrossVolumes(source, target: target, collision: collision)
        }
    }

    static func moveAcrossVolumes(_ source: URL, target: URL, collision: CollisionChoice,
                                  trashDirectory: () throws -> URL = userTrash,
                                  copy: (URL, URL) throws -> Void = FileManager.default.copyItem) throws -> URL {
        try moveHeldSource(source, target: target, collision: collision,
                           expected: nil, tryRename: false, trashDirectory: trashDirectory, copy: copy)
    }

    private static func moveHeldSource(_ source: URL, target: URL, collision: CollisionChoice,
                                       expected: ExistingDestination?, tryRename: Bool,
                                       trashDirectory: () throws -> URL,
                                       copy: (URL, URL) throws -> Void) throws -> URL {
        let holding = try temporaryDirectory(in: source.deletingLastPathComponent(), prefix: "YeeX Move Recovery ")
        // Remove the holding directory only when it is empty. A failed restore must keep the original.
        defer { _ = rmdir(holding.path) }
        let original = holding.appendingPathComponent(source.lastPathComponent)
        if let expected, existingDestination(at: source) != expected { throw TransferError.sourceChanged }
        guard renamex_np(source.path, original.path, UInt32(RENAME_EXCL)) == 0 else { throw posix(errno) }

        let output: URL
        let beforeCopy: [Data: ExistingDestination]
        do {
            if let expected, !expected.matchesRenamedEntry(existingDestination(at: original)) { throw TransferError.sourceChanged }
            if tryRename {
                do {
                    return try publish(original, target: target, collision: collision)
                } catch let error as POSIXError where error.code == .EXDEV {
                    // The original remains in the holding directory for the copy below.
                }
            }
            beforeCopy = try sourceSnapshot(at: original)
            output = try publishCopy(original, target: target, collision: collision) { input, payload in
                try copy(input, payload)
                guard try sourceSnapshot(at: input) == beforeCopy else { throw TransferError.sourceChanged }
            }
        } catch {
            if let transferError = error as? TransferError,
               case .replacementRecoveryRequired = transferError, !exists(original) {
                // The source rename succeeded. Only the previous destination needs recovery.
                throw transferError
            }
            try restoreSource(original, to: source, after: error)
        }
        do {
            guard try sourceSnapshot(at: original) == beforeCopy else { throw TransferError.sourceChanged }
            let trash = try trashDirectory()
            let trashed = trash.appendingPathComponent(source.lastPathComponent)
            // This is a rename only. If Trash is on another volume, leave the original in recovery.
            _ = try publish(original, target: trashed, collision: .keepBoth)
        } catch {
            throw TransferError.partialMove(destination: output, original: original, error: error)
        }
        return output
    }

    private static func restoreSource(_ original: URL, to source: URL, after error: any Error) throws -> Never {
        guard renamex_np(original.path, source.path, UInt32(RENAME_EXCL)) == 0 else {
            throw TransferError.recoveryRequired(original: original, error: error)
        }
        throw error
    }

    private static func sourceSnapshot(at root: URL) throws -> [Data: ExistingDestination] {
        var pending = [(url: root, relativePath: "")]
        var entries: [Data: ExistingDestination] = [:]
        while let item = pending.popLast() {
            var info = stat()
            guard lstat(item.url.path, &info) == 0 else { throw posix(errno) }
            let version = ExistingDestination(info)
            entries[Data(item.relativePath.utf8)] = version
            // lstat leaves symbolic links as entries rather than following them out of the package.
            if version.isDirectory {
                let prefix = item.relativePath.isEmpty ? "" : item.relativePath + "/"
                for name in try FileManager.default.contentsOfDirectory(atPath: item.url.path) {
                    pending.append((item.url.appendingPathComponent(name), prefix + name))
                }
            }
        }
        return entries
    }

    private static func userTrash() throws -> URL {
        try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    private static func publishCopy(_ source: URL, target: URL, collision: CollisionChoice,
                                    copy: (URL, URL) throws -> Void) throws -> URL {
        let directory = try temporaryDirectory(in: target.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appendingPathComponent(target.lastPathComponent)
        try copy(source, payload)
        return try publish(payload, target: target, collision: collision)
    }

    private static func temporaryDirectory(in parent: URL, prefix: String = ".YeeX-transfer-") throws -> URL {
        let directory = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private static func publish(_ source: URL, target: URL, collision: CollisionChoice) throws -> URL {
        var output = target
        var number = 0
        while renamex_np(source.path, output.path, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            guard code == EEXIST || code == ENOTEMPTY else { throw posix(code) }
            switch collision {
            case .fail:
                throw TransferError.destinationExists
            case .replace(let expected):
                try replace(source, target: output, expected: expected)
                return output
            case .keepBoth:
                number += 1
                let ext = target.pathExtension
                let stem = target.deletingPathExtension().lastPathComponent
                let name = "\(stem)-\(number)" + (ext.isEmpty ? "" : ".\(ext)")
                output = target.deletingLastPathComponent().appendingPathComponent(name)
            }
        }
        return output
    }

    private static func replace(_ source: URL, target: URL, expected: ExistingDestination) throws {
        var sourceInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0 else { throw posix(errno) }
        guard !expected.isDirectory, sourceInfo.st_mode & S_IFMT != S_IFDIR else {
            throw TransferError.directoryCollision
        }
        let holding = try temporaryDirectory(in: target.deletingLastPathComponent(), prefix: "YeeX Replace Recovery ")
        defer { _ = rmdir(holding.path) }
        let retained = holding.appendingPathComponent(target.lastPathComponent)
        guard existingDestination(at: target) == expected else { throw TransferError.destinationChanged }
        guard renamex_np(target.path, retained.path, UInt32(RENAME_EXCL)) == 0 else { throw posix(errno) }

        // Validate the exact entry we took, then publish without overwriting anything newly placed at the target.
        do {
            guard expected.matchesRenamedEntry(existingDestination(at: retained)) else { throw TransferError.destinationChanged }
            guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                if code == EEXIST || code == ENOTEMPTY { throw TransferError.destinationChanged }
                throw posix(code)
            }
        } catch {
            guard renamex_np(retained.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
                throw TransferError.replacementRecoveryRequired(retained: retained, error: error)
            }
            throw error
        }

        do {
            try FileManager.default.removeItem(at: retained)
        } catch {
            throw TransferError.replacementRecoveryRequired(retained: retained, error: error)
        }
    }

    private static func posix(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
