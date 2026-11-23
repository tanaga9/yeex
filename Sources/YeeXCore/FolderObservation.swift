import Foundation

public struct FolderObservation {
    public enum PollAction: Equatable { case keepPolling, scan, requireReload, idle }

    public private(set) var scanning = false
    public private(set) var requiresReload = false
    private var retrying = false
    private var snapshot: Set<String>?
    private var checkOverlap = false
    private var idlePolls = 0

    public init() {}

    public mutating func begin() {
        retrying = retrying || requiresReload
        requiresReload = false
        scanning = true
    }

    public mutating func finish(_ result: ScanResult?) {
        scanning = false
        if let result {
            snapshot = result.candidateNames
            checkOverlap = true
        } else {
            requiresReload = requiresReload || retrying
        }
        idlePolls = 0
        retrying = false
    }

    /// Return true if an automatic scan should begin.
    public mutating func changed() -> Bool {
        if scanning { requiresReload = true }
        return !scanning && !requiresReload
    }

    public mutating func poll(_ names: Set<String>) -> PollAction {
        guard !scanning, !requiresReload else { return .requireReload }
        let firstAfterScan = checkOverlap
        checkOverlap = false
        guard let previous = snapshot else {
            snapshot = names
            return .keepPolling
        }
        if names != previous {
            idlePolls = 0
            if firstAfterScan {
                requiresReload = true
                return .requireReload
            }
            return .scan
        }
        idlePolls += 1
        if idlePolls >= 30 { idlePolls = 0; return .idle }
        return .keepPolling
    }
}
