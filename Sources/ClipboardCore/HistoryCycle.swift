import Foundation

/// Keeps shortcut navigation stable while restored entries move to the front.
public struct HistoryCycle {
    private var snapshot: [UUID] = []
    private var index: Int?
    private var expectedChangeCount: Int?

    public init() {}

    public mutating func next(
        in entryIDs: [UUID], changeCount: Int, currentEntryID: UUID?
    ) -> UUID? {
        guard !entryIDs.isEmpty else {
            reset()
            return nil
        }
        let available = Set(entryIDs)
        if expectedChangeCount != changeCount || !snapshot.contains(where: available.contains) {
            snapshot = entryIDs
            index = currentEntryID.flatMap { snapshot.firstIndex(of: $0) }
        }
        expectedChangeCount = changeCount

        // Retain positions in the snapshot so removing an item does not skip its successor.
        let startingIndex = index ?? -1
        for offset in 1...snapshot.count {
            let candidateIndex = (startingIndex + offset) % snapshot.count
            let candidate = snapshot[candidateIndex]
            if available.contains(candidate) {
                index = candidateIndex
                return candidate
            }
        }
        return nil
    }

    public mutating func didRestore(changeCount: Int) {
        expectedChangeCount = changeCount
    }

    public mutating func reset() {
        snapshot = []
        index = nil
        expectedChangeCount = nil
    }
}
