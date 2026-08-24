import SwiftUI

/// Shared empty-state scaffold used by pages whose content lands in a later phase.
///
/// Deliberately explicit rather than a blank view: a page that renders nothing is
/// indistinguishable from a page that failed to load.
struct PagePlaceholder: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let identifier: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .accessibilityIdentifier(identifier)
    }
}
