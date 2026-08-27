import MacNetInterfaces
import MacNetModels
import SwiftUI

/// Localized presentation for the model enums.
///
/// The enums themselves live in the shared package, which has no localization resources and is
/// also linked by the helper — a root daemon has no business carrying user-facing translations.
/// Their `displayName` is therefore the English technical term, which is the right thing for a
/// log export (keeps technical output in English) and the wrong thing for a label
/// on screen.
///
/// These map the same values through the app's string catalog, so the UI follows the user's
/// language while exports stay stable.
extension LogCategory {
    var localizedName: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .dhcp: "DHCP"
        case .dns: "DNS"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}

extension NetworkInterfaceKind {
    var localizedName: LocalizedStringKey {
        switch self {
        case .ethernet: "Ethernet"
        case .wifi: "Wi-Fi"
        case .loopback: "Loopback"
        case .bridge: "Bridge"
        case .vpn: "VPN"
        case .virtual: "Virtual"
        case .unknown: "Unknown"
        }
    }

    /// The same value as a `String`, for places that compose one line out of several fields.
    var localizedNameString: String {
        String(localized: String.LocalizationValue(displayName))
    }
}
