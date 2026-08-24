import SwiftUI

struct LogsView: View {
    var body: some View {
        PagePlaceholder(
            systemImage: "text.alignleft",
            title: "Logs",
            message: "Live dnsmasq output appears here while a session is running.",
            identifier: "logs.page"
        )
    }
}
