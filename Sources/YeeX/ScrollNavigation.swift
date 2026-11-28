import Foundation

@MainActor
final class ScrollNavigation: NSObject {
    private(set) var amount = SIMD2<Double>(repeating: 0)
    private var lastNavigation = ProcessInfo.processInfo.systemUptime
    private var decayTimer: Timer?
    private let isFree: () -> Bool
    private let onDecay: (() -> Void)?

    init(isFree: @escaping () -> Bool, onDecay: (() -> Void)? = nil) {
        self.isFree = isFree
        self.onDecay = onDecay
    }

    func accumulate(_ delta: Double, vertical: Bool, inputPerStep: Double? = nil,
                    travelReachedStep: Bool = false) -> Bool? {
        let free = isFree()
        let axis = vertical ? 1 : 0
        let limit = free ? 1000.0 : (vertical ? 120.0 : 100.0)
        let threshold = vertical || free ? 100.0 : 80.0
        let sensitivity = inputPerStep.map { threshold / $0 } ?? (vertical ? 2.5 : (free ? 0.5 : 0.8))
        if delta * amount[axis] < 0 { amount[axis] = 0 }
        amount[axis] = max(-limit, min(limit, amount[axis] + delta * sensitivity))

        if decayTimer == nil {
            let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(decay), userInfo: nil, repeats: true)
            decayTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard travelReachedStep || abs(amount[axis]) >= threshold,
              free || now - lastNavigation > 0.2 else { return nil }
        let forward = amount[axis] > 0
        amount[axis] /= free ? 1.1 : (vertical ? 100 : 2)
        lastNavigation = now
        return forward
    }

    @objc private func decay() {
        amount.x *= isFree() ? 0.9 : 0.5
        amount.y *= 0.7
        for axis in 0..<2 where abs(amount[axis]) < 1 { amount[axis] = 0 }
        if amount == .zero { stopDecay() }
        onDecay?()
    }

    func stopDecay() {
        decayTimer?.invalidate()
        decayTimer = nil
        amount = .zero
    }
}
