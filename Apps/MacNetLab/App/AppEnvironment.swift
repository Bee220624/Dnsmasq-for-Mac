import Foundation

/// Read-only facts about this build and this machine, resolved once at launch.
///
/// Everything here comes from the bundle's Info.plist, which XcodeGen populates from
/// `Config/Identifiers.xcconfig`. Nothing is hardcoded, so renaming the product before
/// release stays a one-file change (ticket §3.1).
struct AppEnvironment: Sendable {
    let appVersion: String
    let buildNumber: String
    let bundleIdentifier: String
    let helperLabel: String
    let machServiceName: String
    let protocolVersion: Int
    let operatingSystemVersion: String
    let architecture: String

    static func resolve(bundle: Bundle = .main) -> AppEnvironment {
        let info = bundle.infoDictionary ?? [:]

        func string(_ key: String, default fallback: String) -> String {
            (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let protocolText = string("MNLProtocolVersion", default: "")

        return AppEnvironment(
            appVersion: string("CFBundleShortVersionString", default: "0.0.0"),
            buildNumber: string("CFBundleVersion", default: "0"),
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            helperLabel: string("MNLHelperLabel", default: "unknown"),
            machServiceName: string("MNLMachServiceName", default: "unknown"),
            protocolVersion: Int(protocolText) ?? -1,
            operatingSystemVersion:
                "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            architecture: Self.currentArchitecture
        )
    }

    /// Reports the slice actually executing, so a Rosetta-translated launch is visible in
    /// Settings rather than being reported as native.
    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}
