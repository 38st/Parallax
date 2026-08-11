import Foundation

enum SettingsExactPreadStage: Equatable, Sendable {
    case content
    case trailingByte
}

enum SettingsExactPreadAttempt: Equatable, Sendable {
    case bytes(Int)
    case failure(code: Int32)
}

enum SettingsExactPreadInterruptPolicy: Equatable, Sendable {
    case singleAttempt
    case retry(maximumConsecutive: Int)
}

struct SettingsExactPreadRetryPolicy: Equatable, Sendable {
    let interruptedCode: Int32
    let content: SettingsExactPreadInterruptPolicy
    let trailingByte: SettingsExactPreadInterruptPolicy
}

enum SettingsExactPreadFailure: Error, Equatable, Sendable {
    case invalidByteCount(Int)
    case invalidInterruptLimit(
        stage: SettingsExactPreadStage,
        maximumConsecutive: Int
    )
    case system(
        stage: SettingsExactPreadStage,
        code: Int32
    )
    case interruptLimitExceeded(
        stage: SettingsExactPreadStage,
        code: Int32,
        maximumConsecutive: Int
    )
    case noContentProgress
    case invalidReadCount(
        stage: SettingsExactPreadStage,
        actual: Int,
        maximum: Int
    )
    case trailingData
}

enum SettingsExactPread {
    typealias Read = (
        _ destination: UnsafeMutableRawPointer,
        _ offset: Int,
        _ requestedByteCount: Int
    ) -> SettingsExactPreadAttempt

    static func read(
        byteCount: Int,
        retryPolicy: SettingsExactPreadRetryPolicy,
        read: Read,
        trailingRead: Read
    ) -> Result<Data, SettingsExactPreadFailure> {
        guard byteCount >= 0 else {
            return .failure(.invalidByteCount(byteCount))
        }
        if case .retry(let maximum) = retryPolicy.content,
           maximum < 0
        {
            return .failure(
                .invalidInterruptLimit(
                    stage: .content,
                    maximumConsecutive: maximum
                )
            )
        }
        if case .retry(let maximum) = retryPolicy.trailingByte,
           maximum < 0
        {
            return .failure(
                .invalidInterruptLimit(
                    stage: .trailingByte,
                    maximumConsecutive: maximum
                )
            )
        }

        var bytes = Data(count: byteCount)
        var offset = 0
        var consecutiveInterrupts = 0
        while offset < byteCount {
            let requested = byteCount - offset
            let attempt = bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else {
                    return SettingsExactPreadAttempt.bytes(0)
                }
                return read(
                    base.advanced(by: offset),
                    offset,
                    requested
                )
            }
            switch attempt {
            case .bytes(let count):
                guard count >= 0, count <= requested else {
                    return .failure(
                        .invalidReadCount(
                            stage: .content,
                            actual: count,
                            maximum: requested
                        )
                    )
                }
                guard count > 0 else {
                    return .failure(.noContentProgress)
                }
                consecutiveInterrupts = 0
                offset += count
            case .failure(let code):
                guard code == retryPolicy.interruptedCode else {
                    return .failure(.system(stage: .content, code: code))
                }
                switch retryPolicy.content {
                case .singleAttempt:
                    return .failure(.system(stage: .content, code: code))
                case .retry(let maximum):
                    consecutiveInterrupts += 1
                    guard consecutiveInterrupts <= maximum else {
                        return .failure(
                            .interruptLimitExceeded(
                                stage: .content,
                                code: code,
                                maximumConsecutive: maximum
                            )
                        )
                    }
                }
            }
        }

        var trailingByte: UInt8 = 0
        var trailingInterrupts = 0
        while true {
            let attempt = withUnsafeMutablePointer(to: &trailingByte) {
                trailingRead(
                    UnsafeMutableRawPointer($0),
                    byteCount,
                    1
                )
            }
            switch attempt {
            case .bytes(0):
                return .success(bytes)
            case .bytes(1):
                return .failure(.trailingData)
            case .bytes(let count):
                return .failure(
                    .invalidReadCount(
                        stage: .trailingByte,
                        actual: count,
                        maximum: 1
                    )
                )
            case .failure(let code):
                guard code == retryPolicy.interruptedCode else {
                    return .failure(
                        .system(stage: .trailingByte, code: code)
                    )
                }
                switch retryPolicy.trailingByte {
                case .singleAttempt:
                    return .failure(
                        .system(stage: .trailingByte, code: code)
                    )
                case .retry(let maximum):
                    trailingInterrupts += 1
                    guard trailingInterrupts <= maximum else {
                        return .failure(
                            .interruptLimitExceeded(
                                stage: .trailingByte,
                                code: code,
                                maximumConsecutive: maximum
                            )
                        )
                    }
                }
            }
        }
    }
}
