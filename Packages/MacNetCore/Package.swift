// swift-tools-version: 6.0

import PackageDescription

// MacNetCore holds every piece of logic that is shared between the SwiftUI app and the
// privileged helper, and that can be unit tested without root, without a network
// interface, and without touching the file system.
//
// Layering rule (enforced by the dependency graph below): nothing in this package may
// import AppKit/SwiftUI, and nothing may perform privileged work. The config generator in
// particular is a pure function — ticket §9.1 forbids it from touching the file system.

let package = Package(
    name: "MacNetCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacNetModels", targets: ["MacNetModels"]),
        .library(name: "MacNetValidation", targets: ["MacNetValidation"]),
        .library(name: "MacNetDnsmasq", targets: ["MacNetDnsmasq"]),
        .library(name: "MacNetLeases", targets: ["MacNetLeases"]),
        .library(name: "MacNetLogging", targets: ["MacNetLogging"]),
        .library(name: "MacNetXPC", targets: ["MacNetXPC"]),
    ],
    targets: [
        // Value types crossing the XPC boundary. No behaviour beyond Codable conformance.
        .target(name: "MacNetModels"),

        // The security boundary's vocabulary: strict parsing and range checking. The helper
        // re-runs everything here on input it receives; the app runs it for live feedback.
        .target(name: "MacNetValidation", dependencies: ["MacNetModels"]),

        // Deterministic dnsmasq configuration + hosts file rendering.
        .target(name: "MacNetDnsmasq", dependencies: ["MacNetModels", "MacNetValidation"]),

        // dnsmasq lease file parsing.
        .target(name: "MacNetLeases", dependencies: ["MacNetModels", "MacNetValidation"]),

        // Log line classification and the bounded ring buffer backing the Logs UI.
        .target(name: "MacNetLogging", dependencies: ["MacNetModels"]),

        // XPC protocol declaration and request/response envelopes.
        .target(name: "MacNetXPC", dependencies: ["MacNetModels"]),

        .testTarget(name: "MacNetValidationTests", dependencies: ["MacNetValidation"]),
        // Golden files rather than inline literals: the expected dnsmasq configuration is
        // the specification, and keeping it as a readable file makes a diff in review show
        // exactly what changed about the generated output.
        .testTarget(
            name: "MacNetDnsmasqTests",
            dependencies: ["MacNetDnsmasq"],
            resources: [.copy("Golden")]
        ),
        .testTarget(name: "MacNetLeaseTests", dependencies: ["MacNetLeases"]),
        .testTarget(name: "MacNetLoggingTests", dependencies: ["MacNetLogging"]),
        .testTarget(name: "MacNetXPCTests", dependencies: ["MacNetXPC"]),
    ],
    swiftLanguageModes: [.v6]
)
