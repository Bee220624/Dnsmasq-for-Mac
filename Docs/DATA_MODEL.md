# Data Model

Every type crossing a process boundary or reaching disk is `Codable`, `Sendable`, and
`Equatable`. Identifiers are `UUID`. Dates are `Date` in memory and ISO-8601 on the wire.

## One rule worth stating up front

**Timestamps carry whole seconds only.** ISO-8601 without fractional seconds cannot represent
sub-second precision, so a `Date()` straight from the clock does not survive a round trip.
`ProfileStore` verifies every save by reading the file back and comparing — an in-memory value
that is unrepresentable on disk makes that check fail on *every successful save*.
`NetworkProfile` therefore normalizes in `init` and on assignment, so the invariant holds however
a value is constructed rather than requiring every call site to remember.

## Persisted documents

### `~/Library/Application Support/com.bee.macnetlab/profiles-v1.json`

```
ProfileDatabase
├── schemaVersion: Int
├── defaultProfileID: UUID
└── profiles: [NetworkProfile]
```

A document that decodes but violates its invariants — no profiles, duplicate ids, a default that
is not present, an unsupported schema version — is treated as **corrupt**, not accepted. That is
more dangerous than a parse failure, because it would otherwise pass silently.

Written atomically: encode, write a temporary file in the same directory, `fsync`, copy the
current file to `backups/profiles-v1.previous.json`, replace, then read back and compare. The
`fsync` matters — a rename is durable long before the bytes are.

On corruption: the damaged file is moved aside (never overwritten), the previous backup is
tried, and only if that also fails is a fresh default created.

### `/var/db/com.bee.macnetlab/active-session.json`

```
SessionJournal
├── schemaVersion, sessionID, state: JournalState
├── interfaceBSDName, serverIPv4, prefixLength
├── aliasAddedByApp: Bool           ← the single most important field
├── interfaceWasUpBeforeStart: Bool
├── dnsmasqPID, dnsmasqExecutableSHA256
├── configurationPath, leasePath, logPath
└── startedAt, updatedAt
```

`aliasAddedByApp` decides whether an address is ours to remove. An address the user configured
themselves is never touched, however tempting it looks during cleanup.

`dnsmasqExecutableSHA256` is what lets a recycled PID be told from the process we started,
before any signal is sent.

## Profiles

```
NetworkProfile
├── name, createdAt, updatedAt
├── InterfaceConfiguration { addTemporaryIPv4Alias, serverIPv4, prefixLength }
├── DHCPConfiguration { enabled, rangeStart, rangeEnd, leaseDurationSeconds,
│                       authoritative, advertiseRouter, routerIPv4,
│                       advertiseLocalDNSServer }
└── DNSConfiguration  { enabled, localDomain, upstreamMode,
                        customUpstreamServers, logQueries, records: [LocalDNSRecord] }
```

**A profile never names an interface.** Ticket §6.2 is explicit, and the reasons are practical:
a USB adapter's BSD name changes between reboots and ports, the same profile on another Mac
would name a different interface, and an automatic binding could silently select a production
port. The most recently used interface is remembered in `UserDefaults` as a convenience, and the
user still confirms it before every start.

## Session types

`SessionDraft` is what a start request is built from — a **snapshot**, not a live profile. A
profile is a document the user may edit or delete at any moment; a running session must keep
referring to exactly what it was started with. That is also what makes it safe to delete a
profile a live session is using.

`SessionDraft.safetyConfirmation` travels inside the request so the **helper** can refuse a start
that lacks it, rather than trusting the UI to have asked.

`ActiveSession` is what is running, including the profile and interface snapshots, the PID, and
whether the alias was ours.

## Runtime state

```
RuntimeState = stopped | preflighting | starting | running(ActiveSession)
             | stopping | recovering | failed(ServiceFailure)
```

One enum, never several booleans. Booleans admit "running and stopping" and "stopped with a live
PID", and every impossible combination needs handling somewhere.

## Failures

`ServiceFailure` carries a closed `ServiceErrorCode`, a title, a message, an optional recovery
suggestion, optional technical detail, and whether retrying could plausibly help.

The presentation travels *with* the error because the helper knows what actually went wrong; the
UI guessing from a code would produce worse text. Failures cross XPC as `NSError` with the
encoded payload in `userInfo`, so a transport breakage stays distinguishable from a reported
failure — one means the helper is gone, the other means it answered and said no.

## Lease and log types

`DHCPLease.id` is `"<mac>|<ipv4>"`. Neither field alone is unique — one MAC holds different
addresses over time, one address is reused across devices — and the pair is what keeps table rows
stable across renewals.

`LogEvent.sequence` is monotonic within a session and never reset. It is what makes reconnection
exact: the app asks for everything after the highest sequence it holds and receives no gaps and
no duplicates. `timestamp` is when the helper *read* the line, not when dnsmasq wrote it —
dnsmasq's own timestamps have no year and no time zone, so reconstructing an absolute time from
them would be guesswork.

## Wire limits

Requests are capped at 1 MiB and responses at 4 MiB (ticket §7.10), checked **before** decoding
so an oversized payload is never parsed. `[String: Any]` is never used as a wire format: every
payload decodes into an explicit named type, or is rejected.
