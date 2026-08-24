# The Privileged Helper

MacNetLab needs root to add an IP alias to an interface and to run dnsmasq on ports 53 and
67. The app itself never has root. Instead it ships a small LaunchDaemon,
`com.bee.macnetlab.helper`, which runs as root and exposes a fixed set of operations over XPC.

This document covers how that helper is installed, approved, repaired, and removed, and what
verification stands between a caller and root.

---

## 1. Where it lives

The helper and its launchd description ship inside the app bundle:

```
MacNetLab.app/
└── Contents/
    └── Library/
        ├── HelperTools/
        │   ├── com.bee.macnetlab.helper     ← the daemon executable
        │   └── dnsmasq                       ← the bundled engine (Phase 4)
        └── LaunchDaemons/
            └── com.bee.macnetlab.helper.plist
```

The plist's `BundleProgram` is a path *relative to the app bundle*, which is what ties the
daemon to the app that registered it. `SMAppService` remembers the registering bundle's
location, so **the app must live somewhere stable**. A daemon registered from a DerivedData
path stops working the moment that path changes; `Scripts/install-dev-app.sh` stages builds
into `/Applications` for exactly this reason.

The plist deliberately omits `RunAtLoad`, `KeepAlive`, and `StartInterval`. The helper starts
on demand when the app connects to its Mach service, and nothing about this product ever runs
at boot. `Scripts/verify-bundle.sh` fails the build if any of those keys reappear.

---

## 2. Installing

### For users

1. Move **MacNetLab.app** to your Applications folder.
2. Open it. Settings shows the helper as **Not installed**.
3. Click **Install Helper**.
4. macOS reports that approval is required. Click **Open Login Items Settings**.
5. In **System Settings › General › Login Items & Extensions**, enable **MacNetLab**.
6. Return to MacNetLab. It re-checks on its own and connects — no restart needed.

Step 5 cannot be skipped or automated. macOS deliberately requires a human to approve a
root daemon, and there is no API to grant it.

### For development

```bash
make build
Scripts/install-dev-app.sh
```

The script verifies the bundle, removes any previously registered helper (a stale
registration pointing at an old copy is the most common source of confusing failures), copies
the app to `/Applications` with `ditto` so nested signatures survive, and re-verifies the
installed copy. Then follow the user steps above.

To watch what the helper does:

```bash
log stream --predicate 'subsystem == "com.bee.macnetlab.helper"' --level debug
```

---

## 3. What the app does with the status

`SMAppService.Status` maps onto exactly one thing the user can do:

| Status | Meaning | What the app shows |
|---|---|---|
| `notRegistered` | Never installed here | **Install Helper** |
| `requiresApproval` | Registered; waiting on the user | **Open Login Items Settings**, then polls |
| `enabled` | Approved and reachable | Connects and handshakes |
| `notFound` | The daemon plist is missing from the bundle | "Reinstall MacNetLab" — a build or copy problem, not a user error |

When the status is `requiresApproval`, the app polls every two seconds until it changes and
then reconnects. It does **not** call `register()` again in a loop: repeating the call cannot
grant the approval, and hammering it only produces noise in the system log.

Once connected, the app calls `getServiceInfo` before anything else, and refuses to proceed
unless the helper reports effective UID 0 and the same protocol version. A mismatch is
surfaced as **Repair Helper** rather than being worked around.

---

## 4. How the helper decides who may talk to it

This is the security boundary of the whole product. If it is wrong, MacNetLab is a local
privilege escalation.

The helper constrains its listener before accepting anything:

```swift
listener.setConnectionCodeSigningRequirement(requirement)
```

with

```
identifier "com.bee.macnetlab" and anchor apple generic and certificate leaf[subject.OU] = "MDUMXF88CA"
```

macOS evaluates this against the **peer's audit token** inside the kernel, before our delegate
is consulted. A connection that fails never reaches MacNetLab's code at all.

The three clauses each close a different hole:

- `identifier` — the caller is *this* program, not another app from the same team.
- `anchor apple generic` — the signature chains to an Apple-issued certificate, so a
  self-signed or ad-hoc binary claiming the same identifier is rejected.
- `certificate leaf[subject.OU]` — the leaf certificate belongs to our team, so another
  developer cannot ship an app with our identifier and be trusted.

### What is deliberately not used

UID, PID, executable file name, and bundle path are all rejected as evidence. A PID can be
recycled between the check and the use, and a path says nothing about what is actually
executing there. Ticket §10.4 forbids relying on any of them, and
`setConnectionCodeSigningRequirement` exists precisely because those patterns were widespread
and wrong.

### There is no relaxed development mode

The ticket permits a weaker `#if DEBUG` policy. This build does not have one. The requirement
above is satisfied by a locally development-signed build, because the Team ID appears in the
leaf certificate's OU for Apple Development certificates just as it does for Developer ID. A
security check that only runs in release is a security check that is never exercised.

The helper still reports its build type, and Settings displays a development build plainly, so
a debug helper is never mistaken for a release one.

### Mutual authentication

The app pins the helper the same way, with `NSXPCConnection.setCodeSigningRequirement`. Both
requirements are produced by one shared implementation, `CodeSigningRequirement`, so the two
directions cannot drift apart. Its behaviour — including rejection of inputs that would alter
the requirement's meaning — is covered by the tests in `MacNetXPCTests`.

### Failing closed

If the helper cannot build a requirement — a corrupt Info.plist, a missing Team ID — it logs a
fault and exits. It does not start an unconstrained listener. Likewise, a helper that finds
itself running with a non-zero effective UID exits immediately rather than continuing in a
state where its operations would fail confusingly later.

---

## 5. Repairing

Choose **Repair Helper** in Settings when the helper is reported as incompatible or
unavailable. This re-registers the daemon, which is the right response after upgrading the app
or moving it.

If the app will not launch at all, the escape hatch is:

```bash
Scripts/uninstall-dev-helper.sh
```

which boots the daemon out of launchd. It does **not** run `sfltool resetbtm`: that clears the
background task database for the entire Mac, not just this app. It is mentioned in the
script's output as a last resort for the user to decide on, never run automatically.

---

## 6. Removing

In Settings, choose **Remove Helper**. This calls `SMAppService.unregister()`.

Removal is refused while a session is running (ticket §5.7). Unregistering the helper
underneath a live dnsmasq would strand the process and leave the temporary IP alias in place,
with nothing left running that knows how to clean either of them up.

After removal, macOS may still list MacNetLab under Login Items & Extensions. That record is
kept independently of launchd's loaded state and can be removed there.

---

## 7. Verification status

The following are verified on this machine:

- The helper reads its embedded Info.plist at runtime and reports version `0.1.0`,
  protocol `1`.
- The helper refuses to run as a non-root user: it logs a fault and exits `1`.
- The requirement string is syntactically valid, accepted by `csreq`.
- The requirement accepts the real signed app bundle and rejects the helper binary,
  `/bin/ls`, a wrong Team ID, and a wrong bundle identifier.
- The bundle layout, identifiers, signature, hardening, and dependencies all pass
  `make verify-bundle`.

**Not yet verified:** the live `SMAppService` registration, the approval flow, and a real XPC
round trip to a launchd-started root helper. All three require a human to approve the daemon
in System Settings, which cannot be automated. See `Docs/RISKS.md` R-02.

To complete this verification:

```bash
make build
Scripts/install-dev-app.sh
```

then follow §2, and confirm in Settings that the helper reports **Installed and running**
with effective UID 0.
