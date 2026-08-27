# Dnsmasq for Mac v0.1 — Risk Register

Opened **2026-08-25**, before any code was written.

Severity: **S1** blocks release · **S2** blocks a feature · **S3** degrades quality.
Status: `open` · `mitigated` · `accepted` · `open`.

---

## R-01 — No Developer ID certificate; release signing and notarization cannot be completed

**Severity:** S1 · **Status:** `open`

The only codesigning identity on this machine is `Apple Development` (Team `MDUMXF88CA`).
Distribution outside the Mac App Store requires a `Developer ID Application` certificate
plus notarization credentials, so that the ticket can be stapled to the app.

*Impact.* Signed distribution cannot be completed here. The privileged helper is **not**
blocked: `SMAppService`
daemon registration works with a development-signed app for local testing, with the user
approving the daemon in System Settings → General → Login Items.

*Mitigation.* `DEVELOPMENT_TEAM` and the signing identity live only in
`Config/Identifiers.xcconfig`. All signing behaviour is driven from `Scripts/build-release.sh`
and validated by `Scripts/verify-bundle.sh`, so switching identities is a one-file change
plus a re-run. Everything not dependent on Developer ID is implemented and tested.

*What needs doing.* Obtain a Developer ID Application certificate and configure a notarytool
keychain profile, then run `make verify-bundle` and the release checklist in `Docs/RELEASE.md`.

---

## R-02 — `SMAppService` daemon approval is user-gated and cannot be scripted

**Severity:** S2 · **Status:** `open`

`SMAppService.daemon(plistName:).register()` may return `requiresApproval`, leaving the
daemon disabled until a human toggles it in System Settings. There is no API to grant this,
and it is deliberately not scriptable.

*Impact.* No fully automated end-to-end test of the privileged path is possible; the first
run on any machine needs one manual approval.

*Mitigation.* The specification is implemented literally: never loop on `register()`, surface the
exact status, offer **Open Login Items Settings**, and observe status changes so the app
reconnects once approval lands. The manual step is scripted as far as it can be in
`Scripts/install-dev-app.sh` and documented in `Docs/PRIVILEGED_HELPER.md`.

*Also note.* The app must run from a stable location. A daemon registered from a
`DerivedData` path breaks as soon as that path changes, so the dev install script stages the
app into `/Applications`.

---

## R-03 — Helper caller validation is the single security boundary

**Severity:** S1 · **Status:** `open`

The helper runs as root and accepts XPC from the app. If caller validation is weak, any
local process gains a root-privileged network-configuration interface.

*Impact.* Worst case is local privilege escalation.

*Mitigation.* `CallerValidator` verifies the peer via its **audit token**
(`SecCodeCopyGuestWithAttributes` + `kSecGuestAttributeAudit`) against a designated
requirement pinning both bundle identifier and Team ID — never UID, PID, executable name, or
bundle path. Per the specification the relaxed development policy is compiled out entirely under
`#if DEBUG`; `Scripts/verify-bundle.sh` fails the build if a release bundle carries the debug
security flag. Malicious-input coverage lives in the security unit tests.

*Residual.* Audit-token APIs used here are effectively required for correctness but parts are
not formally public API. Reviewed against Apple's own sample guidance; revisit on each major
macOS release.

---

## R-04 — DHCP on a production network can cause an outage

**Severity:** S1 · **Status:** `mitigated`

A rogue DHCP server on a live network hands out addresses to machines that already have
them. In a datacenter this is a serious, visible incident.

*Mitigation.* Layered and enforced in the helper, not only the UI:
Wi-Fi is permanently barred from DHCP in v0.1; the current default-route interface is
barred; loopback/VPN/bridge/AWDL/utun are barred; an explicit isolation confirmation is
required, is never persisted, and resets on stop, interface change, and pool change; the
listener is pinned with `interface=`/`bind-interfaces`; and UDP 67 is probed both during
preflight and again after the alias is added.

*Residual.* No amount of software can tell an isolated lab switch from a production one.
The confirmation checkbox is the last line of defence and is deliberately unskippable.

---

## R-05 — Temporary IP alias can leak if rollback fails

**Severity:** S2 · **Status:** `open`

An alias added to an interface but not removed leaves the Mac holding an address it should
not have, which can itself cause a conflict.

*Mitigation.* Every side effect is recorded in an atomically-updated journal
(`/var/db/com.bee.dnsmasqformac/active-session.json`) before and after it happens. Start is a
transaction with reverse-order rollback. Only aliases recorded with
`aliasAddedByApp = true` are ever removed, so a user's own addresses are never touched.
Removal is verified with `getifaddrs`. On helper restart the journal drives recovery.

*Residual.* If alias removal genuinely fails, the app must not hide it: state moves to
cleanup-failure and the UI shows the exact interface, address, and a manual recovery command.
A hard power loss between two journal writes is handled by the recovery path on next start.

---

## R-06 — dnsmasq is GPL; distribution obligations must be met

**Severity:** S1 · **Status:** `open`

dnsmasq is licensed GPL v2 *or* GPL v3, at the distributor's choice. Shipping it inside a
distributed `.app` triggers source-availability and notice obligations.

*Mitigation.* dnsmasq stays a **separate executable**, invoked via config file and process
management. No dnsmasq object code is linked into any Swift binary and no dnsmasq C source is
compiled into the app executable, keeping the boundary at arm's length. `COPYING`,
`COPYING-v3`, the exact version, the official source URL, the build script, and any patches
are retained and surfaced in Settings → Licenses.

*Release gate.* The source archive is deliberately not committed to git — the build fetches it
from a pinned URL and verifies a pinned digest, which is better than a blob in history. But
reproducibility is not the same as the distribution obligation: `Scripts/package-release.sh`
must ship the verified `dnsmasq-<VERSION>.tar.xz`, `Scripts/build-dnsmasq.sh`, and both
licence texts *alongside the distributed app*, not merely cite where they came from.

*What needs doing.* The specification is explicit that the final licence of Dnsmasq for Mac itself is
**not** an implementation decision. A legal review is required before commercial
distribution. `LICENSE_PENDING` is intentionally left in place.

---

## R-07 — Universal 2 build correctness

**Severity:** S2 · **Status:** `open`

dnsmasq is a C project built via its own Makefile, not Xcode. Building two architectures in
one tree easily produces object-file cross-contamination, and a stray Homebrew include path
silently introduces a `/opt/homebrew` dylib dependency that will fail on a clean Mac.

*Mitigation.* `Scripts/build-dnsmasq.sh` uses a **separate clean build directory per
architecture**, merges with `lipo`, then asserts on the merged binary: both slices present via
`lipo -info`; `otool -L` shows system libraries only; and `--version` output confirms `DHCP`
is compiled in while TFTP, DHCPv6, scripts, auth, and dumpfile are not. `verify-bundle.sh`
repeats the architecture and dependency assertions on the shipped bundle.

*Note.* This host is arm64 only, so the x86_64 slice is cross-compiled and **cannot be
executed here**. Runtime verification of the Intel slice requires an Intel Mac or Rosetta.

---

## R-08 — dnsmasq privilege drop to `nobody` is unverified on macOS

**Severity:** S2 · **Status:** `open`

The generated config sets `user=nobody` / `group=nobody` per the specification On macOS `nobody`
is uid/gid `-2` (`4294967294` unsigned), which is unusual compared with Linux. dnsmasq opens
its DHCP, raw, and ICMP sockets before dropping privileges, so this is expected to work, but
it is not proven on this platform.

*Impact.* If the drop fails, dnsmasq exits at startup and Start fails cleanly — a visible
failure, not a silent one.

*Mitigation.* Runtime files (`dnsmasq.leases`, `dnsmasq.log`, `dnsmasq.pid`) are pre-created
`nobody:nobody 0640` so dnsmasq never needs write access to the session directory itself.
Must be confirmed by the session lifecycle tests and Manual Test A before release.

---

## R-09 — Preflight-to-start race on port availability

**Severity:** S3 · **Status:** `mitigated`

Ports 53/67 can be taken by another process between preflight and start.

*Mitigation.* The specification Step 12 re-probes UDP 67 and TCP/UDP 53 *after* the alias is added
and immediately before launch; a conflict at that point rolls the alias back. Preflight is
advisory; the check inside the start transaction is authoritative.

---

## R-10 — macOS 14 deployment target is not testable on this host

**Severity:** S3 · **Status:** `open`

Development happens on macOS 15.7.9. The product targets macOS 14.0. `SMAppService` approval
flow and Login Items UI differ between the two.

*Mitigation.* Deployment target is pinned to 14.0 in `Config/Base.xcconfig` so the compiler
rejects newer-only API. Final manual verification on a genuine macOS 14 machine is a release
gate recorded in `Docs/MANUAL_TEST_PLAN.md`.

---

## R-11 — UI tests need Accessibility permission for the process that runs them

**Severity:** S3 · **Status:** `open`(affects every phase with UI tests)

XCUITest drives another application, which macOS gates behind Accessibility permission. The
grant belongs to **whichever process runs the tests** — not to Dnsmasq for Mac, and not to the test
bundle.

Confirmed on this machine:

```
AXIsProcessTrusted() = false
```

and the resulting failures:

```
Failed to load AX for com.bee.dnsmasqformac (pid:…): Not authorized for performing UI testing actions.
"sidebar.overview" Button exists but never became hittable
```

Both are the same cause. Without the grant, XCUITest can see elements in the accessibility tree
but cannot hit-test them, so `isHittable` never becomes true and clicks fail.

### What needs doing

**System Settings → Privacy & Security → Accessibility**, then enable the app you launch the
tests from:

| How you run them | What to enable |
|---|---|
| `make test-ui` in Terminal | **Terminal** |
| `make test-ui` in iTerm | **iTerm** |
| Test navigator in Xcode | **Xcode** |

The grant persists once given. Then:

```bash
make test-ui      # or make test-all for everything
```

### What was already fixed

The first real run surfaced three defects **in the tests**, all since corrected:

1. **Locale dependence.** Assertions compared against English while the app ran in Simplified
   Chinese, so `"已停止"` failed against `"Stopped"`. Tests now launch with
   `-AppleLanguages "(en)"`, so they test the product rather than the tester's system language.
2. **Restored window geometry.** macOS had persisted a split-view 2174 pt tall on a 944 pt
   screen, putting the sidebar above the visible area. Tests now launch with
   `-ApplePersistenceIgnoreState YES`, and the stale defaults were cleared.
3. **Asserting before async state settled.** Helper status begins as "checking"; tests asserted
   on the action buttons before it resolved. They now wait.

Tests that depend on the helper being installed now `XCTSkipUnless` rather than failing, so a
machine without the helper reports them as skipped — which is true — instead of broken.

---

## R-12 — The dnsmasq signing key's provenance is asserted, not independently established

**Severity:** S2 · **Status:** `open`

`Scripts/build-dnsmasq.sh` verifies the upstream archive two ways: its SHA-256 must match
`Resources/ThirdParty/dnsmasq/SHA256SUMS`, and its detached OpenPGP signature must verify
**and** be made by the fingerprint in `SIGNING_KEY_FINGERPRINT`:

```
D6EACBD6EE46B834248D111215CDDA6AE19135A2
```

That key carries the user IDs `Simon Kelley <simon@thekelleys.org.uk>` and
`Simon Kelley <srk@debian.org>`, and the signature on the 2.93 archive verifies against it.

*The gap.* The fingerprint was taken from the signature it is used to check. The upstream site
publishes no key file, and the archive contains none, so within this repository the assertion
is self-referential: it proves the archive was signed by whoever signed it. Pinning the
fingerprint still has real value — it means a compromised keyserver produces a build failure
rather than a silent key substitution — but it is not a trust root.

*Mitigation.* The SHA-256 pin is independent of the signature entirely, and is the check that
actually holds the line for the specific artefact vetted here. Both must pass.

*What needs doing.* Corroborate the fingerprint against a source that does not derive
from thekelleys.org.uk. The Debian keyring is the natural choice, since the same person
maintains dnsmasq there. Record the result in
`Resources/ThirdParty/dnsmasq/SIGNING_KEY_FINGERPRINT` alongside where it was confirmed.

---

## R-13 — The specification's launch-time SHA-256 check is not constructible as written

**Severity:** S2 · **Status:** `mitigated`

The specification specifies: compute the dnsmasq digest at build time, generate a Swift constant
from it, and have the helper recompute the digest before every launch and refuse to start on a
mismatch.

*Why it cannot work as written.* `codesign` embeds the signature **inside** the Mach-O, so the
bytes of dnsmasq in the app bundle necessarily differ from the bytes the compiler produced.
The helper is compiled before dnsmasq is copied in and signed, so no constant compiled into
the helper can describe the signed file. The signing identity also differs between Debug
(Apple Development) and Release (Developer ID), so there is no single value that could be
correct for both. Implemented literally, the check would fail on every launch.

*What is implemented instead*, meeting the requirement's intent — never execute a dnsmasq that
is not the one we shipped:

1. **Code signature.** Before launching, the helper verifies the bundled dnsmasq against a
   requirement pinning our Team ID — the same mechanism that authenticates the XPC peer. This
   is stronger than a digest: it proves provenance rather than matching a number that an
   attacker able to replace the binary could equally replace.
2. **File properties.** Regular file, not a symlink, not group- or world-writable.
3. **Version.** `--version` must report the pinned upstream version, and must show `DHCP`
   compiled in and TFTP, DHCPv6, auth, and dumpfile absent.
4. **Build-time digest.** The SHA-256 of the *unsigned* build artefact is recorded in
   `BINARY_SHA256` and `DnsmasqBinaryIdentity.expectedSHA256`, and `verify-bundle.sh` checks
   it against `dist/dnsmasq`. This answers a different and still useful question: did we ship
   the dnsmasq we built?

*What needs doing.* This is a deliberate deviation from the specification. Confirm the substitution
is acceptable, or specify a two-pass build that signs dnsmasq, digests the signed file, then
rebuilds the helper with that value — at the cost of a build that must run twice and a digest
that differs per signing identity.

---

## R-14 — Log category precedence departs from the specified order

**Severity:** S3 · **Status:** `mitigated`

The specification lists the log categories as DHCP, DNS, Warning, Error, System. Read as a
precedence order, that misfiles real dnsmasq output:

```
dnsmasq[421]: cannot read config file
```

contains `config` — a DNS keyword — and `cannot` — an error keyword. With DNS tried first the
line is filed under DNS, so an engineer filtering to **Error** never learns that their
configuration could not be read. That is exactly the moment the Error filter exists for.

*What is implemented.* Severity is evaluated first: **Warning, Error, DHCP, DNS, System**.
Warning precedes Error because dnsmasq labels its own non-fatal problems `warning:`, and
promoting those to errors would cry wolf.

Keywords are also matched as whole words rather than substrings, so `errors` does not read as
`error` and `replying` does not read as `reply`.

*Cost.* None in practice: dnsmasq's DHCP message types never appear inside its failure text, so
ordinary lease traffic still classifies as DHCP — while `failed to send DHCPOFFER` now reaches
someone filtering for failures. Covered by `LogClassifierTests.severityWinsOverProtocol`.

*What needs doing.* Confirm the reordering is acceptable, or say which behaviour you prefer for a
line that is both a protocol event and a failure.
