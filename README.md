# MacNetLab

A native macOS tool for engineers who walk into a datacenter with nothing but a MacBook and a
USB-C-to-Ethernet adapter.

Select a wired interface, pick a profile, and MacNetLab brings up a temporary DHCPv4 and DNS
environment on that interface only — no Terminal, no `ifconfig`, no editing
`/etc/dnsmasq.conf`, and no permanent change to any macOS network service. Stop the session
and the Mac is exactly as it was.

> **Status: v0.1 in development.** See `Docs/RISKS.md` for what is not yet verified.

## What it does

- Enumerate network interfaces with hardware name, BSD name, type, MAC, link state, and
  whether the interface carries the default route.
- Add a **temporary** IPv4 alias to a chosen wired interface, and remove it on stop.
- Serve DHCPv4 from a single pool on that one interface, with configurable range, lease
  duration, router option, and DNS option.
- Serve DNS: forward to the system resolvers, to custom upstreams, or answer local records
  only. Local A records and DHCP client hostnames resolve under a local domain such as
  `lab.test`.
- Show live leases and categorized live logs, and export logs as plain text.
- Save reusable profiles.

## What it deliberately does not do

No TFTP, PXE, DHCPv6, NAT, IP forwarding, internet sharing, bridging, or VLANs. No telemetry,
analytics, crash reporting, accounts, or cloud sync. Nothing starts automatically, and only
one session runs at a time. The full exclusion list is ticket §2.2; the deferred list is §29.

## Architecture

```
MacNetLab.app  (SwiftUI, runs as you — never root)
      │
      │  NSXPCConnection — structured Codable payloads only,
      │  caller verified by audit token + Team ID
      ▼
com.bee.macnetlab.helper  (LaunchDaemon, root, on-demand via SMAppService)
      │
      │  fixed executable path, argument arrays, never a shell
      ▼
bundled dnsmasq  (DHCPv4 + DNS only)
```

The app never runs as root. The helper exposes a fixed whitelist of operations — it accepts
no arbitrary command, path, or executable — and re-validates every parameter it receives.
Details in `Docs/ARCHITECTURE.md`, `Docs/SECURITY.md`, and `Docs/PRIVILEGED_HELPER.md`.

## Requirements

- macOS 14.0 or later
- Xcode 26 or later (full Xcode, not just Command Line Tools)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Getting started

```bash
make bootstrap     # install dev tooling, generate the Xcode project
make build         # build the app and the privileged helper
make test          # package + integration suites
```

`MacNetLab.xcodeproj` is **generated output** and is not committed. `project.yml` is the
source of truth; run `make generate` after changing it and never edit `project.pbxproj`.

### Running it for real

The privileged helper needs a one-time approval before anything can start:

```bash
make install-dev   # stage a signed build into /Applications
```

then open the app and follow the Install Helper flow, which will send you to
**System Settings › General › Login Items & Extensions**. Full walkthrough, including repair
and uninstall, is in `Docs/PRIVILEGED_HELPER.md`.

### UI tests

`make test` deliberately excludes the UI suites, because XCUITest needs Accessibility
permission for **the process that runs the tests** — Terminal, iTerm, or Xcode, depending on
how you launch them.

Grant it once in **System Settings → Privacy & Security → Accessibility**, then:

```bash
make test-ui       # UI suites only
make test-all      # everything
```

Without the grant the failures read as `Not authorized for performing UI testing actions` and
`exists but never became hittable`. Both are the same missing permission. See
`Docs/RISKS.md` R-11.

## Third-party software

MacNetLab bundles **dnsmasq** by Simon Kelley, licensed GPL v2 or GPL v3, as a separate
unmodified executable — no dnsmasq code is linked into any MacNetLab binary. Licences,
version, upstream source URL, and the build script are retained under
`Resources/ThirdParty/dnsmasq/` and shown in Settings › Licenses. See
`Docs/THIRD_PARTY_NOTICES.md`.

The licence of MacNetLab itself is **not yet decided** and requires legal review before any
commercial distribution; `LICENSE_PENDING` is intentional.

## Roadmap

Deferred to v0.2 and later, and explicitly not implemented in v0.1: DHCP static reservations,
TFTP and PXE (with options 66/67), an HTTP file server, ARP viewer, BMC discovery, ping and
port check tools, profile import/export, multiple interfaces, DNS CNAME/AAAA records, DHCPv6,
a menu bar mode, automatic updates, and Japanese localization.
