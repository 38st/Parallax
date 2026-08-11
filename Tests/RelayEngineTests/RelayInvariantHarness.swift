import Foundation

struct RelayInvariantViolation: Error, Equatable, Sendable {
    let sequenceIndex: Int
    let eventIndex: Int?
    let rule: String
}

/// Generic reducer verifier shared by RelayCore and RelayEngine tests.
/// Production adapters provide the event sequences and canonical state bytes.
struct RelayInvariantHarness<State, Event> {
    typealias Reducer = (State, Event) throws -> State
    typealias Fingerprint = (State) throws -> Data
    typealias Rule = (State) -> String?

    let initialState: State
    let reduce: Reducer
    let fingerprint: Fingerprint
    let rules: [Rule]

    func verify(sequences: [[Event]]) -> [RelayInvariantViolation] {
        var violations: [RelayInvariantViolation] = []
        for (sequenceIndex, sequence) in sequences.enumerated() {
            do {
                let first = try replay(
                    sequence,
                    sequenceIndex: sequenceIndex,
                    violations: &violations,
                    evaluateRules: true
                )
                var secondRunViolations: [RelayInvariantViolation] = []
                let second = try replay(
                    sequence,
                    sequenceIndex: sequenceIndex,
                    violations: &secondRunViolations,
                    evaluateRules: false
                )
                if try fingerprint(first) != fingerprint(second) {
                    violations.append(
                        RelayInvariantViolation(
                            sequenceIndex: sequenceIndex,
                            eventIndex: nil,
                            rule: "same event sequence produced different state"
                        )
                    )
                }
                violations.append(contentsOf: secondRunViolations)
            } catch {
                violations.append(
                    RelayInvariantViolation(
                        sequenceIndex: sequenceIndex,
                        eventIndex: nil,
                        rule: "replay threw: \(String(describing: error))"
                    )
                )
            }
        }
        return violations
    }

    private func replay(
        _ sequence: [Event],
        sequenceIndex: Int,
        violations: inout [RelayInvariantViolation],
        evaluateRules: Bool
    ) throws -> State {
        var state = initialState
        for (eventIndex, event) in sequence.enumerated() {
            state = try reduce(state, event)
            for rule in evaluateRules ? rules : [] {
                if let failure = rule(state) {
                    violations.append(
                        RelayInvariantViolation(
                            sequenceIndex: sequenceIndex,
                            eventIndex: eventIndex,
                            rule: failure
                        )
                    )
                }
            }
        }
        return state
    }
}

/// Stable, dependency-free generated sequences. The same seed and event set
/// always yield the same sequences on every supported host.
enum RelayInvariantSequenceGenerator {
    static func generate<Event>(
        events: [Event],
        seed: UInt64,
        sequenceCount: Int,
        maximumLength: Int
    ) -> [[Event]] {
        guard !events.isEmpty, sequenceCount > 0, maximumLength > 0 else {
            return []
        }
        var generator = RelayFixturePRNG(state: seed)
        return (0..<sequenceCount).map { _ in
            let length = Int(generator.next() % UInt64(maximumLength)) + 1
            return (0..<length).map { _ in
                events[Int(generator.next() % UInt64(events.count))]
            }
        }
    }
}

private struct RelayFixturePRNG {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
