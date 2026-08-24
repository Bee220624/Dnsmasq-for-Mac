import SwiftUI

struct LeasesView: View {
    var body: some View {
        PagePlaceholder(
            systemImage: "list.bullet.rectangle",
            title: "Leases",
            message: "No active DHCP session.",
            identifier: "leases.page"
        )
    }
}
