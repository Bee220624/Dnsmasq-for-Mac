import SwiftUI

struct OverviewView: View {
    var body: some View {
        PagePlaceholder(
            systemImage: "network",
            title: "Overview",
            message: "Profile, interface, DHCP, DNS, safety, and preflight cards are added in later phases.",
            identifier: "overview.page"
        )
    }
}
