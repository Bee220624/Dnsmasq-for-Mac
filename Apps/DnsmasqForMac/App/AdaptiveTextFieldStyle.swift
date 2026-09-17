import SwiftUI

extension View {
    /// Keep older SDK builds usable while adopting the native macOS 27 input controls.
    @ViewBuilder
    func appTextFieldStyle() -> some View {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            self.textFieldStyle(.bordered)
                .textInputBorderShape(.roundedRectangle)
        } else {
            self.textFieldStyle(.roundedBorder)
        }
        #else
        self.textFieldStyle(.roundedBorder)
        #endif
    }
}
