import SwiftUI

struct ProfilesView: View {
    var body: some View {
        PagePlaceholder(
            systemImage: "square.stack.3d.up",
            title: "Profiles",
            message: "Saved network presets are managed here.",
            identifier: "profiles.page"
        )
    }
}
