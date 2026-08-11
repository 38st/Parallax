import CoreFoundation
import Foundation

/// A Codable JSON value used by Relay's test fixtures without relying on
/// untyped, non-Sendable Foundation dictionaries.
enum RelayFixtureJSON: Codable, Equatable, Sendable {
    case object([String: RelayFixtureJSON])
    case array([RelayFixtureJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RelayFixtureJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RelayFixtureJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    init(foundation value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
            self = .bool(value.boolValue)
        case let value as NSNumber:
            guard value.doubleValue.isFinite else {
                throw RelayFakeAppServerError.invalidJSON
            }
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(RelayFixtureJSON.init(foundation:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(RelayFixtureJSON.init(foundation:)))
        default:
            throw RelayFakeAppServerError.invalidJSON
        }
    }

    var foundationValue: Any {
        switch self {
        case let .object(value): return value.mapValues(\.foundationValue)
        case let .array(value): return value.map(\.foundationValue)
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case .null: return NSNull()
        }
    }
}

enum RelayFakeRequestIDExpectation: Equatable, Sendable {
    case any
    case absent
    case exact(Int)
}

enum RelayFakeAppServerOutput: Equatable, Sendable {
    case result(RelayFixtureJSON)
    case error(code: Int, message: String)
    case notification(method: String, params: RelayFixtureJSON)
    case rawLine(Data)
}

struct RelayFakeAppServerStep: Equatable, Sendable {
    let method: String
    let id: RelayFakeRequestIDExpectation
    let outputs: [RelayFakeAppServerOutput]
    let closesAfterOutput: Bool

    init(
        method: String,
        id: RelayFakeRequestIDExpectation = .any,
        outputs: [RelayFakeAppServerOutput] = [],
        closesAfterOutput: Bool = false
    ) {
        self.method = method
        self.id = id
        self.outputs = outputs
        self.closesAfterOutput = closesAfterOutput
    }
}

enum RelayFakeAppServerError: Error, Equatable {
    case closed
    case bufferLimitExceeded
    case lineLimitExceeded
    case invalidJSON
    case unexpectedRequest(expected: String?, actual: String?)
    case unexpectedID(expected: RelayFakeRequestIDExpectation, actual: Int?)
    case responseRequiresRequestID
    case invalidRawLine
}

/// A deterministic JSON-lines app-server fixture.
///
/// Tests feed arbitrarily fragmented client bytes and receive complete server
/// frames. There are no sleeps, subprocesses, or ambient clocks. A scripted
/// step is consumed only after its method and request ID have been validated.
final class RelayFakeAppServer: @unchecked Sendable {
    private static let maximumBufferedBytes = 256 * 1_024
    private static let maximumLineBytes = 64 * 1_024

    private let lock = NSLock()
    private var buffer = Data()
    private var remainingSteps: [RelayFakeAppServerStep]
    private var requests: [RelayFixtureJSON] = []
    private var serverClosed = false

    init(steps: [RelayFakeAppServerStep]) {
        remainingSteps = steps
    }

    var transcript: [RelayFixtureJSON] {
        lock.withLock { requests }
    }

    var unconsumedStepCount: Int {
        lock.withLock { remainingSteps.count }
    }

    var isClosed: Bool {
        lock.withLock { serverClosed }
    }

    func receive(_ bytes: Data) throws -> [Data] {
        try lock.withLock {
            guard !serverClosed else { throw RelayFakeAppServerError.closed }
            guard !bytes.isEmpty else { return [] }
            buffer.append(bytes)
            guard buffer.count <= Self.maximumBufferedBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw RelayFakeAppServerError.bufferLimitExceeded
            }

            var frames: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer.prefix(upTo: newline))
                buffer.removeSubrange(...newline)
                guard line.count <= Self.maximumLineBytes else {
                    throw RelayFakeAppServerError.lineLimitExceeded
                }
                guard !line.isEmpty else { continue }
                frames.append(contentsOf: try consume(line: line))
                if serverClosed { break }
            }
            return frames
        }
    }

    func finishInput() throws {
        try lock.withLock {
            guard buffer.isEmpty else { throw RelayFakeAppServerError.invalidJSON }
        }
    }

    private func consume(line: Data) throws -> [Data] {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let request = object as? [String: Any]
        else {
            throw RelayFakeAppServerError.invalidJSON
        }
        let method = request["method"] as? String
        guard let step = remainingSteps.first, step.method == method else {
            throw RelayFakeAppServerError.unexpectedRequest(
                expected: remainingSteps.first?.method,
                actual: method
            )
        }
        let requestID = exactIntegerID(request["id"])
        guard idMatches(step.id, actual: requestID) else {
            throw RelayFakeAppServerError.unexpectedID(
                expected: step.id,
                actual: requestID
            )
        }

        let typedRequest = try RelayFixtureJSON(foundation: request)
        remainingSteps.removeFirst()
        requests.append(typedRequest)

        let frames = try step.outputs.map { output in
            try frame(output: output, requestID: requestID)
        }
        if step.closesAfterOutput { serverClosed = true }
        return frames
    }

    private func frame(
        output: RelayFakeAppServerOutput,
        requestID: Int?
    ) throws -> Data {
        let object: [String: Any]
        switch output {
        case let .result(result):
            guard let requestID else {
                throw RelayFakeAppServerError.responseRequiresRequestID
            }
            object = ["id": requestID, "result": result.foundationValue]
        case let .error(code, message):
            guard let requestID else {
                throw RelayFakeAppServerError.responseRequiresRequestID
            }
            object = [
                "id": requestID,
                "error": ["code": code, "message": message],
            ]
        case let .notification(method, params):
            object = ["method": method, "params": params.foundationValue]
        case let .rawLine(data):
            guard !data.contains(0x0A) else {
                throw RelayFakeAppServerError.invalidRawLine
            }
            return data + Data([0x0A])
        }

        guard JSONSerialization.isValidJSONObject(object) else {
            throw RelayFakeAppServerError.invalidJSON
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    private func idMatches(
        _ expectation: RelayFakeRequestIDExpectation,
        actual: Int?
    ) -> Bool {
        switch expectation {
        case .any: true
        case .absent: actual == nil
        case let .exact(expected): actual == expected
        }
    }

    private func exactIntegerID(_ value: Any?) -> Int? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard
            double.isFinite,
            double.rounded(.towardZero) == double,
            abs(double) <= 9_007_199_254_740_991
        else { return nil }
        return Int(double)
    }
}
