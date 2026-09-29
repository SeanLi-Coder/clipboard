import Foundation
import Testing
@testable import ClipboardCore

@Suite("History shortcut navigation")
struct HistoryCycleTests {
    @Test
    func testRestoringItemsDoesNotBounceBetweenTheTwoNewestEntries() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var cycle = HistoryCycle()
        #expect(cycle.next(in: [a, b, c, d], changeCount: 10, currentEntryID: a) == b)
        cycle.didRestore(changeCount: 12)
        #expect(cycle.next(in: [b, a, c, d], changeCount: 12, currentEntryID: b) == c)
        cycle.didRestore(changeCount: 14)
        #expect(cycle.next(in: [c, b, a, d], changeCount: 14, currentEntryID: c) == d)
        cycle.didRestore(changeCount: 16)
        #expect(cycle.next(in: [d, c, b, a], changeCount: 16, currentEntryID: d) == a)
        cycle.didRestore(changeCount: 18)
        #expect(cycle.next(in: [a, d, c, b], changeCount: 18, currentEntryID: a) == b)
    }

    @Test
    func testExternalCopyStartsANewCycleFromItsNewOrder() {
        let a = UUID(), b = UUID(), c = UUID(), newlyCopied = UUID()
        var cycle = HistoryCycle()
        #expect(cycle.next(in: [a, b, c], changeCount: 10, currentEntryID: a) == b)
        cycle.didRestore(changeCount: 12)
        #expect(cycle.next(in: [newlyCopied, b, a, c], changeCount: 14, currentEntryID: newlyCopied) == b)
        cycle.didRestore(changeCount: 16)
        #expect(cycle.next(in: [b, newlyCopied, a, c], changeCount: 16, currentEntryID: b) == a)
    }

    @Test
    func testUnrecordedClipboardStartsAtMostRecentSavedEntry() {
        let a = UUID(), b = UUID(), c = UUID()
        var cycle = HistoryCycle()
        #expect(cycle.next(in: [a, b, c], changeCount: 10, currentEntryID: nil) == a)
        cycle.didRestore(changeCount: 12)
        #expect(cycle.next(in: [a, b, c], changeCount: 12, currentEntryID: a) == b)
    }

    @Test
    func testDeletionSkipsMissingItemsWithoutLosingSnapshotOrder() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var cycle = HistoryCycle()
        #expect(cycle.next(in: [a, b, c, d], changeCount: 10, currentEntryID: a) == b)
        cycle.didRestore(changeCount: 12)
        #expect(cycle.next(in: [b, a, d], changeCount: 12, currentEntryID: b) == d)
        cycle.didRestore(changeCount: 14)
        #expect(cycle.next(in: [a], changeCount: 14, currentEntryID: nil) == a)
    }

    @Test
    func testFailedRestoreCanAdvanceWithoutAClipboardChange() {
        let a = UUID(), missingFile = UUID(), c = UUID()
        var cycle = HistoryCycle()
        #expect(cycle.next(in: [a, missingFile, c], changeCount: 10, currentEntryID: a) == missingFile)
        #expect(cycle.next(in: [a, missingFile, c], changeCount: 10, currentEntryID: a) == c)
    }

    @Test
    func testManualChoiceResetsTheCycle() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        var cycle = HistoryCycle()
        #expect(cycle.next(in: [a, b, c, d], changeCount: 10, currentEntryID: a) == b)
        cycle.didRestore(changeCount: 12)
        cycle.reset()
        #expect(cycle.next(in: [d, b, a, c], changeCount: 14, currentEntryID: d) == b)
    }

    @Test
    func testEmptyAndSingleEntryHistoriesRemainSafe() {
        let a = UUID()
        var cycle = HistoryCycle()
        #expect(cycle.next(in: [], changeCount: 10, currentEntryID: nil) == nil)
        #expect(cycle.next(in: [a], changeCount: 12, currentEntryID: a) == a)
        cycle.didRestore(changeCount: 14)
        #expect(cycle.next(in: [a], changeCount: 14, currentEntryID: a) == a)
        #expect(cycle.next(in: [], changeCount: 14, currentEntryID: a) == nil)
        #expect(cycle.next(in: [a], changeCount: 14, currentEntryID: nil) == a)
    }
}
