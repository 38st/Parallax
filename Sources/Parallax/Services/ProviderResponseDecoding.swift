import AppKit
import CoreFoundation
import Foundation
import os

enum ProviderNumericDecoder {
    static let maximumExactInteger = 9_007_199_254_740_991.0
    static let maximumUnixTimestamp = 32_503_680_000.0

    static func percentage(_ value: Any?) -> Int? {
        guard
            let number = finiteDouble(value),
            number >= 0
        else {
            return nil
        }
        return Int(min(number, 100).rounded())
    }

    static func tokenCount(_ value: Any?) -> Int? {
        guard
            let number = finiteDouble(value),
            number >= 0,
            number <= maximumExactInteger,
            number.rounded(.towardZero) == number
        else {
            return nil
        }
        return Int(number)
    }

    static func unixDate(_ value: Any?) -> Date? {
        guard
            let number = finiteDouble(value),
            (0...maximumUnixTimestamp).contains(number)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: number)
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else {
                return nil
            }
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value)
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }
}

struct ClaudeAuthenticationStatus: Equatable, Sendable {
    let isAuthenticated: Bool
    let email: String?
    let planName: String?
}

enum ClaudeAuthenticationStatusDecoder {
    static func decode(_ output: String) throws -> ClaudeAuthenticationStatus {
        guard
            let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            throw AIAccountConnectionError.statusUnavailable
        }
        guard let isAuthenticated = strictBoolean(json["loggedIn"])
            ?? strictBoolean(json["isAuthenticated"])
        else {
            // Authentication state is security-sensitive. Unknown or changed
            // provider schemas must not be promoted to a signed-in state.
            throw AIAccountConnectionError.statusUnavailable
        }
        let email = json["email"] as? String
            ?? (json["account"] as? [String: Any])?["email"] as? String
        let plan = json["subscriptionType"] as? String
            ?? json["plan"] as? String
            ?? json["authMethod"] as? String
        return ClaudeAuthenticationStatus(
            isAuthenticated: isAuthenticated,
            email: email,
            planName: plan
        )
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.boolValue
    }
}
