import Foundation

public enum PreflightSeverity: String, Codable, Sendable, Equatable, Comparable, CaseIterable {
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }

    public static func < (lhs: PreflightSeverity, rhs: PreflightSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// One finding from preflight.
public struct PreflightIssue: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let severity: PreflightSeverity
    public let title: String
    public let message: String
    public let recoverySuggestion: String?

    public init(
        id: String,
        severity: PreflightSeverity,
        title: String,
        message: String,
        recoverySuggestion: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }
}

/// The checks preflight runs, in the order the UI lists them.
///
/// An enum rather than free-form strings so the UI can render the full checklist — including
/// checks that have not run yet — instead of only showing what happened to fail.
public enum PreflightCheck: String, Codable, Sendable, CaseIterable, Identifiable {
    case helperInstalled
    case helperVersionCompatible
    case dnsmasqBinaryVerified
    case interfaceSupported
    case interfaceIsNotDefaultRoute
    case ipv4ConfigurationValid
    case dhcpPoolValid
    case dnsConfigurationValid
    case requiredPortsAvailable
    case generatedConfigurationValid

    public var id: String { rawValue }
}

public enum PreflightCheckStatus: String, Codable, Sendable, Equatable {
    case pending
    case passed
    case warning
    case failed
}

public struct PreflightCheckResult: Codable, Sendable, Equatable, Identifiable {
    public let check: PreflightCheck
    public let status: PreflightCheckStatus
    /// Issues attributed to this check, if any.
    public let issueIDs: [String]

    public var id: String { check.rawValue }

    public init(check: PreflightCheck, status: PreflightCheckStatus, issueIDs: [String] = []) {
        self.check = check
        self.status = status
        self.issueIDs = issueIDs
    }
}

/// Everything preflight learned about a proposed session.
///
/// Preflight is strictly read-only: it adds no alias, starts no process, and
/// changes no network configuration. Its result is advisory — the same checks run again
/// inside the start transaction, where they are authoritative — because the world can change
/// between validating and starting.
public struct PreflightReport: Codable, Sendable, Equatable {
    public let checks: [PreflightCheckResult]
    public let issues: [PreflightIssue]

    /// Output of `dnsmasq --test`, kept for display when configuration generation fails
    ///.
    public let configurationTestOutput: String?

    public let generatedAt: Date

    public init(
        checks: [PreflightCheckResult],
        issues: [PreflightIssue],
        configurationTestOutput: String? = nil,
        generatedAt: Date
    ) {
        self.checks = checks
        self.issues = issues
        self.configurationTestOutput = configurationTestOutput
        self.generatedAt = generatedAt
    }

    /// Whether anything blocks Start. Warnings never block.
    public var hasBlockingIssues: Bool {
        issues.contains { $0.severity == .error }
    }

    public var warnings: [PreflightIssue] {
        issues.filter { $0.severity == .warning }
    }

    public var errors: [PreflightIssue] {
        issues.filter { $0.severity == .error }
    }

    /// A report with every check pending, for the UI to show before preflight has run.
    public static func pending(at date: Date) -> PreflightReport {
        PreflightReport(
            checks: PreflightCheck.allCases.map {
                PreflightCheckResult(check: $0, status: .pending)
            },
            issues: [],
            generatedAt: date
        )
    }
}
