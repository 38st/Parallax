import AppKit
import Foundation
import Observation

enum CorporateAccountMutationScope: Hashable, Sendable {
    case account(provider: AIProvider, accountID: UUID)
    case provider(AIProvider)

    init(account: TrackedAIAccount) {
        switch account.provider.accountCapabilities.operationScope {
        case .account:
            self = .account(
                provider: account.provider,
                accountID: account.id
            )
        case .provider:
            self = .provider(account.provider)
        }
    }
}

protocol CorporateAccountOperationServicing: Sendable {
    func login(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus

    func refresh(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus
}

struct LiveCorporateAccountOperationService:
    CorporateAccountOperationServicing
{
    func login(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await AIAccountConnectionService.login(
            provider: provider,
            accountID: accountID
        )
    }

    func refresh(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await AIAccountConnectionService.refresh(
            provider: provider,
            accountID: accountID
        )
    }
}

struct CorporateAccountOperationToken: Hashable, Sendable {
    let scope: CorporateAccountMutationScope
    let operationID: UUID
}
