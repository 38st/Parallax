import Darwin
import Foundation

enum DataOperationActivityPolicy: Sendable {
    case requireInactive
    case destructiveExpertOverride(DestructiveActionExecutionAuthorization)
}
