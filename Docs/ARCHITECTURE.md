# Architecture

## The shape of the problem

Serving DHCP and DNS needs root: adding an address to an interface, binding ports 53 and 67.
Everything else — the UI, the profiles, the log viewer — needs no privilege at all and would be
dangerous to grant it.

So the product is split at exactly that line.

```
MacNetLab.app                            runs as you, never as root
  │
  │   NSXPCConnection
  │   structured Codable payloads only, ≤1 MiB request / ≤4 MiB reply
  │   both ends pinned by code signature
  ▼
com.bee.macnetlab.helper                 LaunchDaemon, root, started on demand
  │
  │   fixed executable, argument array, never a shell
  ▼
bundled dnsmasq                          drops to `nobody` once its sockets are open
```

## Where the code lives

| Module | Contains | Links AppKit? |
|---|---|---|
| `MacNetModels` | Value types crossing XPC. No behaviour. | no |
| `MacNetValidation` | Strict parsing and range checking. | no |
| `MacNetInterfaces` | Interface enumeration and the support policy. | no |
| `MacNetDnsmasq` | Deterministic config + hosts generation. | no |
| `MacNetLeases` | Lease file parsing. | no |
| `MacNetLogging` | Log classification and the bounded buffer. | no |
| `MacNetXPC` | Protocol declaration and payload envelopes. | no |
| `Apps/MacNetLab` | SwiftUI, profiles, view models. | yes |
| `Daemons/MacNetLabHelper` | Everything privileged. | no |

Nothing in the shared package imports SwiftUI or performs privileged work. That is what makes
the interesting logic testable without root, without a network adapter, and without a window.

## Why so much is shared rather than duplicated

Ticket §12.4 requires the helper to re-enumerate interfaces and re-validate everything rather
than trusting what the app sent. The obvious reading — write it twice — is wrong: two
implementations of *"may DHCP run on this interface"* will eventually disagree, and the one
that matters is whichever is wrong.

So the *policy* is shared and the *evidence* is not. `InterfaceSupportPolicy` and
`ConfigurationValidator` are one implementation used by both sides; the helper simply runs them
against data it gathered itself, at the moment it matters.

## The three state machines

**`RuntimeState`** — what the service is doing. One enum, never several booleans, because
booleans admit "running and stopping" and every impossible combination needs handling
somewhere.

**`JournalState`** — what the helper has already done to the machine. Persisted after every
side effect, so a helper that restarts knows whether an alias exists and whether a process
does. Without it, recovery would have to guess, and both wrong guesses are bad: an alias
stranded forever, or an address the user configured themselves removed.

**`HelperReadiness`** — whether the app can talk to the helper at all. Each case maps to exactly
one thing the user can do, which is what keeps onboarding from becoming a pile of flags.

## Start is a transaction

Every side effect is journalled before it is reported as done, and every failure unwinds in
reverse order (`RollbackPlan`). The failure modes this exists to prevent are named in ticket
§15.2, and each has a test:

- dnsmasq fails to start but the alias stays behind
- the app shows Stopped while the helper still runs dnsmasq
- the journal points at a process that no longer exists
- nobody can tell which step failed

Rollback continues past its own failures. If terminating the process fails, the alias must
still be removed — stopping at the first error would leave more behind than proceeding does.

## Data flow for one session

1. The app builds a `SessionStartRequest` from the **draft**, not the saved profile: the user
   pressed Start looking at those values.
2. The helper re-validates everything, re-enumerates the interface, and re-verifies the engine.
3. It generates the dnsmasq configuration — a pure function, no file system — writes it
   atomically, and reads it back to confirm.
4. It adds the alias, re-checks the ports now that the address exists, and launches.
5. Watchers for the lease file, the log file, and the process start.
6. The journal reaches `running`.

Stopping unwinds the same list, and removes **only** an alias recorded as added by this app.

## Further reading

`SECURITY.md` for the trust boundaries, `PRIVILEGED_HELPER.md` for installation and caller
verification, `DNSMASQ_BUILD.md` for the vendored engine, `DATA_MODEL.md` for the persisted
formats, and `RISKS.md` for what is known not to be settled.
