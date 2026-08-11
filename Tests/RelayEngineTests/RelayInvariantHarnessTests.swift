import Foundation
import XCTest

final class RelayInvariantHarnessTests: XCTestCase {
    private enum Event: CaseIterable {
        case increment
        case decrement
    }

    func testGeneratedSequencesAreStableForASeed() {
        let first = RelayInvariantSequenceGenerator.generate(
            events: Event.allCases,
            seed: 42,
            sequenceCount: 100,
            maximumLength: 20
        )
        let second = RelayInvariantSequenceGenerator.generate(
            events: Event.allCases,
            seed: 42,
            sequenceCount: 100,
            maximumLength: 20
        )

        XCTAssertEqual(
            first.map { $0.map(String.init(describing:)) },
            second.map { $0.map(String.init(describing:)) }
        )
    }

    func testHarnessFindsInvariantViolationAtExactEvent() throws {
        let harness = RelayInvariantHarness<Int, Event>(
            initialState: 0,
            reduce: { state, event in
                switch event {
                case .increment: state + 1
                case .decrement: state - 1
                }
            },
            fingerprint: { withUnsafeBytes(of: $0.bigEndian) { Data($0) } },
            rules: [
                { $0 < 0 ? "counter became negative" : nil },
            ]
        )

        XCTAssertEqual(
            harness.verify(sequences: [[.increment], [.decrement]]),
            [
                RelayInvariantViolation(
                    sequenceIndex: 1,
                    eventIndex: 0,
                    rule: "counter became negative"
                ),
            ]
        )
    }

    func testDeterministicReducerPassesGeneratedCorpus() {
        let sequences = RelayInvariantSequenceGenerator.generate(
            events: Event.allCases,
            seed: 9_001,
            sequenceCount: 10_000,
            maximumLength: 32
        )
        let harness = RelayInvariantHarness<Int, Event>(
            initialState: 0,
            reduce: { state, event in
                switch event {
                case .increment: state + 1
                case .decrement: state - 1
                }
            },
            fingerprint: {
                withUnsafeBytes(of: $0.bigEndian) { Data($0) }
            },
            rules: []
        )

        XCTAssertEqual(harness.verify(sequences: sequences), [])
    }
}
