import AppKit

// Entry point for the screenshot tool.
//
// Renders each page of Dnsmasq for Mac to a PNG and exits. It compiles the app's own view sources,
// so what it draws is the real UI rather than a reproduction of it.
//
// Usage:
//
//     DnsmasqForMacScreenshots --output <directory> [-AppleLanguages "(zh-Hans)"]
//
// The language is selected the way macOS selects it for any app — through `AppleLanguages` —
// so the output is localized exactly as the shipping app would be in that language.

let arguments = CommandLine.arguments

guard let outputIndex = arguments.firstIndex(of: "--output"),
      arguments.index(after: outputIndex) < arguments.endIndex
else {
    FileHandle.standardError.write(Data("usage: DnsmasqForMacScreenshots --output <directory>\n".utf8))
    exit(EXIT_FAILURE)
}

let outputRoot = URL(fileURLWithPath: arguments[arguments.index(after: outputIndex)])

// `.prohibited` keeps the tool out of the Dock and stops it taking focus. It never shows a
// window: the pages are drawn into an off-screen bitmap.
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)

// AppKit needs to have finished launching before NSHostingView will lay out and draw
// correctly, so the work runs from the run loop rather than inline.
final class ToolDelegate: NSObject, NSApplicationDelegate {
    let outputRoot: URL

    init(outputRoot: URL) {
        self.outputRoot = outputRoot
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                try await PageRenderer(outputRoot: outputRoot).renderPages()
                exit(EXIT_SUCCESS)
            } catch {
                FileHandle.standardError.write(Data("render failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
    }
}

let delegate = ToolDelegate(outputRoot: outputRoot)
application.delegate = delegate
application.run()
