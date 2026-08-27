# Development Environment Audit

Ticket: **MNL-001** — Dnsmasq for Mac v0.1
Audit date: **2026-08-25**

## 1. Host

| Item | Value |
|---|---|
| macOS | 15.7.9 (build 24G830) |
| Architecture | arm64 (Apple Silicon) |
| Xcode | 26.3 (build 17C529) |
| Swift | 6.2.4 (swiftlang-6.2.4.1.4, clang-1700.6.4.2) |
| Default target triple | arm64-apple-macosx15.0 |
| `xcode-select -p` | `/Applications/Xcode.app/Contents/Developer` |

Deployment target for this project is **macOS 14.0**, which is below the host version, so
local builds run on a newer OS than the minimum. Behaviour that differs between macOS 14
and 15 (notably `SMAppService` approval UI) must be verified on a real macOS 14 machine
before release.

## 2. Toolchain availability

| Tool | Path | Status |
|---|---|---|
| `xcodegen` | `/opt/homebrew/bin/xcodegen` | present |
| `git` | `/opt/homebrew/bin/git` | present |
| `make` | `/usr/bin/make` | present |
| `lipo` | `/usr/bin/lipo` | present |
| `codesign` | `/usr/bin/codesign` | present |
| `swift-format` | — | **missing** (optional; formatting only) |

Homebrew is used for *development tooling only*. It is never a runtime dependency of the
shipped app; `Scripts/verify-bundle.sh` enforces this by rejecting any `/opt/homebrew` or
`/usr/local/opt` reference in the shipped binaries.

## 3. Repository baseline

The repository was **empty** apart from the specification this work was written against,
which is not published here. Specifically, at audit time there was no:

- `.xcodeproj` / `.xcworkspace`
- `Package.swift`
- `project.yml` / `Makefile`
- pre-existing privileged helper
- vendored `dnsmasq` binary
- signing configuration

There was no git repository; `git init` was run as part of Phase 0. **No pre-existing code,
configuration, certificate setup, or user data was deleted.** There was no baseline test
suite to run.

## 4. Code signing

`security find-identity -v -p codesigning` reports exactly one identity:

```
Apple Development: <apple-id> (<certificate-id>)
```

Certificate details:

| Field | Value |
|---|---|
| Team ID (OU) | `MDUMXF88CA` |
| Valid | 2026-04-08 → 2027-04-08 |

The Apple ID and per-developer certificate identifier are redacted here, matching the
convention `Scripts/package-release.sh` and `Docs/RELEASE.md` already use for the same values.
The Team ID is not redacted: it is embedded in the designated requirement that authenticates
the XPC peer, is declared in `Config/Identifiers.xcconfig`, and is visible in the signature of
any app signed with it — so it is public by design rather than by accident.

### Consequences

- **Apple Development signing is available.** This is sufficient to register and approve a
  `SMAppService.daemon` locally, so Phase 2 (privileged helper + XPC) can be developed and
  verified on this machine.
- **No `Developer ID Application` certificate is installed**, and no notarization
  credentials are configured. Phase 12 (Developer ID signing, notarization, stapling, and
  distribution outside the Mac App Store) **cannot be completed in this environment**. See
  `Docs/RISKS.md` R-01.

The Team ID is configured in exactly one place, `Config/Identifiers.xcconfig`, and is
consumed by the Xcode targets, the helper's caller-validation code, and the build scripts.
Swapping to a Developer ID identity is a change to that single file plus the signing
identity setting.

## 5. Network access

Outbound HTTPS to `https://thekelleys.org.uk/dnsmasq/` succeeds. The published release
directory contains `dnsmasq-2.93.tar.xz`, confirming the version pinned by ticket §3.4 is
real and fetchable. Source is downloaded at build time by `Scripts/build-dnsmasq.sh` and
verified against a recorded SHA-256; it is never fetched at app runtime.
