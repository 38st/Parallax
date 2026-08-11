import Darwin
import Foundation
@testable import Parallax
import XCTest

final class SettingsExactPreadTests: XCTestCase {
    func testShortReadsAndSeparatedInterruptsPreserveExactOffsets() throws {
        let source = Data("abcdef".utf8)
        var contentCalls: [(offset: Int, requested: Int)] = []
        var contentAttempt = 0
        var trailingCalls = 0

        let result = SettingsExactPread.read(
            byteCount: source.count,
            retryPolicy: policy(
                content: .retry(maximumConsecutive: 1),
                trailing: .retry(maximumConsecutive: 1)
            ),
            read: { destination, offset, requested in
                contentCalls.append((offset, requested))
                contentAttempt += 1
                if contentAttempt == 1 || contentAttempt == 3 {
                    return .failure(code: EINTR)
                }
                let count = min(2, requested)
                source.withUnsafeBytes { raw in
                    destination.copyMemory(
                        from: raw.baseAddress!.advanced(by: offset),
                        byteCount: count
                    )
                }
                return .bytes(count)
            },
            trailingRead: { _, offset, requested in
                trailingCalls += 1
                XCTAssertEqual(offset, source.count)
                XCTAssertEqual(requested, 1)
                return trailingCalls == 1
                    ? .failure(code: EINTR)
                    : .bytes(0)
            }
        )

        XCTAssertEqual(try result.get(), source)
        XCTAssertEqual(
            contentCalls.map(\.offset),
            [0, 0, 2, 2, 4]
        )
        XCTAssertEqual(
            contentCalls.map(\.requested),
            [6, 6, 4, 4, 2]
        )
        XCTAssertEqual(trailingCalls, 2)
    }

    func testContentAndTrailingInterruptBudgetsAreIndependentAndExact() {
        var contentCalls = 0
        let content = SettingsExactPread.read(
            byteCount: 1,
            retryPolicy: policy(
                content: .retry(maximumConsecutive: 2),
                trailing: .singleAttempt
            ),
            read: { _, _, _ in
                contentCalls += 1
                return .failure(code: EINTR)
            },
            trailingRead: { _, _, _ in
                XCTFail("Trailing read must not run after content failure.")
                return .bytes(0)
            }
        )
        XCTAssertEqual(
            content,
            .failure(
                .interruptLimitExceeded(
                    stage: .content,
                    code: EINTR,
                    maximumConsecutive: 2
                )
            )
        )
        XCTAssertEqual(contentCalls, 3)

        var trailingCalls = 0
        let trailing = SettingsExactPread.read(
            byteCount: 1,
            retryPolicy: policy(
                content: .singleAttempt,
                trailing: .retry(maximumConsecutive: 2)
            ),
            read: { destination, _, _ in
                destination.storeBytes(of: UInt8(ascii: "x"), as: UInt8.self)
                return .bytes(1)
            },
            trailingRead: { _, _, _ in
                trailingCalls += 1
                return .failure(code: EINTR)
            }
        )
        XCTAssertEqual(
            trailing,
            .failure(
                .interruptLimitExceeded(
                    stage: .trailingByte,
                    code: EINTR,
                    maximumConsecutive: 2
                )
            )
        )
        XCTAssertEqual(trailingCalls, 3)

        var singleAttemptCalls = 0
        let singleAttempt = SettingsExactPread.read(
            byteCount: 0,
            retryPolicy: policy(
                content: .retry(maximumConsecutive: 2),
                trailing: .singleAttempt
            ),
            read: { _, _, _ in
                XCTFail("Zero-byte content must not read.")
                return .bytes(0)
            },
            trailingRead: { _, _, _ in
                singleAttemptCalls += 1
                return .failure(code: EINTR)
            }
        )
        XCTAssertEqual(
            singleAttempt,
            .failure(.system(stage: .trailingByte, code: EINTR))
        )
        XCTAssertEqual(singleAttemptCalls, 1)
    }

    func testTypedFailuresDistinguishContentAndTrailingOutcomes() {
        XCTAssertEqual(
            read(content: .bytes(0), trailing: .bytes(0)),
            .failure(.noContentProgress)
        )
        XCTAssertEqual(
            read(content: .failure(code: EIO), trailing: .bytes(0)),
            .failure(.system(stage: .content, code: EIO))
        )
        XCTAssertEqual(
            read(content: .bytes(1), trailing: .bytes(1)),
            .failure(.trailingData)
        )
        XCTAssertEqual(
            read(content: .bytes(1), trailing: .failure(code: EIO)),
            .failure(.system(stage: .trailingByte, code: EIO))
        )
        XCTAssertEqual(
            read(content: .bytes(2), trailing: .bytes(0)),
            .failure(
                .invalidReadCount(
                    stage: .content,
                    actual: 2,
                    maximum: 1
                )
            )
        )
    }

    func testInvalidBoundsFailBeforeInvokingCallers() {
        var calls = 0
        let negativeCount = SettingsExactPread.read(
            byteCount: -1,
            retryPolicy: policy(
                content: .singleAttempt,
                trailing: .singleAttempt
            ),
            read: { _, _, _ in
                calls += 1
                return .bytes(0)
            },
            trailingRead: { _, _, _ in
                calls += 1
                return .bytes(0)
            }
        )
        XCTAssertEqual(negativeCount, .failure(.invalidByteCount(-1)))

        let invalidLimit = SettingsExactPread.read(
            byteCount: 0,
            retryPolicy: policy(
                content: .singleAttempt,
                trailing: .retry(maximumConsecutive: -1)
            ),
            read: { _, _, _ in
                calls += 1
                return .bytes(0)
            },
            trailingRead: { _, _, _ in
                calls += 1
                return .bytes(0)
            }
        )
        XCTAssertEqual(
            invalidLimit,
            .failure(
                .invalidInterruptLimit(
                    stage: .trailingByte,
                    maximumConsecutive: -1
                )
            )
        )
        XCTAssertEqual(calls, 0)
    }

    private func read(
        content: SettingsExactPreadAttempt,
        trailing: SettingsExactPreadAttempt
    ) -> Result<Data, SettingsExactPreadFailure> {
        SettingsExactPread.read(
            byteCount: 1,
            retryPolicy: policy(
                content: .singleAttempt,
                trailing: .singleAttempt
            ),
            read: { _, _, _ in content },
            trailingRead: { _, _, _ in trailing }
        )
    }

    private func policy(
        content: SettingsExactPreadInterruptPolicy,
        trailing: SettingsExactPreadInterruptPolicy
    ) -> SettingsExactPreadRetryPolicy {
        .init(
            interruptedCode: EINTR,
            content: content,
            trailingByte: trailing
        )
    }
}
