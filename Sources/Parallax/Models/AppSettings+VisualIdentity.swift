import Foundation
import Observation

extension AppSettings {
    func profileVisualIdentity(
        for profileID: UUID
    ) -> ProfileInstanceVisualIdentity {
        profileVisualIdentities[
            profileID.uuidString.lowercased()
        ] ?? ProfileInstanceVisualIdentity(profileID: profileID)
    }

    func hasProfileVisualIdentity(for profileID: UUID) -> Bool {
        profileVisualIdentities[
            profileID.uuidString.lowercased()
        ] != nil
    }

    func setProfileVisualSymbol(
        _ symbol: ProfileInstanceVisualSymbol,
        for profileID: UUID
    ) {
        guard canModifySettings else { return }
        guard
            ProfileInstanceVisualIdentity
                .selectableSymbols.contains(symbol)
        else { return }
        let current = profileVisualIdentity(for: profileID)
        setProfileVisualIdentity(
            ProfileInstanceVisualIdentity(
                symbol: symbol,
                color: current.color
            ),
            for: profileID
        )
    }

    func setProfileVisualColor(
        _ color: ProfileInstanceVisualColor,
        for profileID: UUID
    ) {
        guard canModifySettings else { return }
        guard
            ProfileInstanceVisualIdentity
                .selectableColors.contains(color)
        else { return }
        let current = profileVisualIdentity(for: profileID)
        setProfileVisualIdentity(
            ProfileInstanceVisualIdentity(
                symbol: current.symbol,
                color: color
            ),
            for: profileID
        )
    }
}
