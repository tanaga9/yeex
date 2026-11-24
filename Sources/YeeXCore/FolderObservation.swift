import Foundation

public struct FolderObservation {
    public enum PollAction: Equatable { case keepPolling, scan, requireReload, idle }

    public private(set) var scanning = false
    public private(set) var requiresReload = false
    private var retrying = false
    private var snapshot: Set<String>?
    private var changedDuringScan = false
    private var idlePolls = 0

    public init() {}

    public mutating func begin() {
        retrying = retrying || requiresReload
        requiresReload = false
        changedDuringScan = false
        scanning = true
    }

    /// Return true if a successful scan should be followed by another scan.
    public mutating func finish(_ result: ScanResult?) -> Bool {
        scanning = false
        if let result {
            snapshot = result.candidateNames
        } else {
            requiresReload = retrying || changedDuringScan
        }
        let scanAgain = result != nil && changedDuringScan
        changedDuringScan = false
        idlePolls = 0
        retrying = false
        return scanAgain
    }

    /// Return true if an automatic scan should begin.
    public mutating func changed() -> Bool {
        if scanning { changedDuringScan = true }
        return !scanning && !requiresReload
    }

    public mutating func poll(_ names: Set<String>) -> PollAction {
        guard !scanning, !requiresReload else { return .requireReload }
        guard let previous = snapshot else {
            snapshot = names
            return .keepPolling
        }
        if names != previous {
            idlePolls = 0
            return .scan
        }
        idlePolls += 1
        if idlePolls >= 30 { idlePolls = 0; return .idle }
        return .keepPolling
    }
}
