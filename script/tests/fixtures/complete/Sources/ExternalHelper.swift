import SwiftUI

func externalLocalizedRow(_ title: LocalizedStringKey) -> some View {
    Text(title)
}

func externalLocalizedValueRow(
    code: Int,
    detail: String.LocalizationValue
) -> some View {
    Text(String(localized: detail))
}
