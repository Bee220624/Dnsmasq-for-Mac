# Security

MacNetLab runs a network service as root on an engineer's machine. This document states what
is defended, how, and what is deliberately not defended.

## Threat model

**Defended against**

1. **Local privilege escalation through the helper.** Any local process could try to drive a
   root-privileged XPC service. This is the one that matters most.
2. **Substitution of the bundled engine.** Replacing `dnsmasq` inside the app bundle would mean
   the helper executing an attacker's binary as root.
3. **Injection through configuration values.** Host names, domains, and interface names are
   written into files a root process reads, and passed as arguments to a root process.
4. **Damage to a network the user did not intend to serve.** Not an attacker — but the most
   likely serious harm this product can do.

**Not defended against**

- A user who already has root. Nothing here is a barrier to someone who can already `sudo`.
- Physical access, or a compromised macOS.
- Malicious *content* in DHCP or DNS traffic. dnsmasq handles the protocols; MacNetLab
  configures and supervises it.

## 1. Who may talk to the helper

The helper constrains its listener before accepting anything:

```swift
listener.setConnectionCodeSigningRequirement(
    #"identifier "com.bee.macnetlab" and anchor apple generic """#
    + #"and certificate leaf[subject.OU] = "<TEAM>""#
)
```

macOS evaluates this against the peer's **audit token**, in the kernel, before our delegate is
consulted. A connection that fails never reaches our code.

Each clause closes a different hole: `identifier` means it is this app and not another from the
same team; `anchor apple generic` means an ad-hoc or self-signed binary claiming that identifier
is rejected; the leaf certificate's OU means another developer cannot ship an app with our
identifier and be trusted.

**Deliberately not used:** UID, PID, executable file name, bundle path. A PID can be recycled
between the check and the use, and a path says nothing about what is executing there. Ticket
§10.4 forbids all four, and `setConnectionCodeSigningRequirement` exists precisely because
those patterns were widespread and wrong.

**There is no relaxed development mode.** The ticket permits a weaker `#if DEBUG` policy; this
build does not have one, because the strict requirement is satisfied by a locally
development-signed build. A security check that only runs in release is one that is never
exercised.

The app pins the helper the same way. Both requirements come from one shared implementation
(`CodeSigningRequirement`), so the two directions cannot drift apart.

## 2. What the helper will do

A closed list (ticket §10.5): report status, run preflight, add an alias, remove an alias it
added, launch the bundled dnsmasq, stop it, read this session's lease and log files, recover
stale state, and verify the engine.

There is **no interface** through which a caller can name a command, an executable, or a path.
The executables the helper may run are an enum of three. Session paths are built from a `UUID`
the helper generated — taking a `UUID` rather than a `String` makes path traversal
unrepresentable rather than merely rejected.

Nothing runs through a shell. Ever. `Process.executableURL` plus an argument array, so a value
cannot become an instruction.

## 3. Verifying the engine

Before launching dnsmasq the helper checks:

1. **Code signature** against a requirement pinned to our Team ID.
2. **File properties**: a regular file (via `lstat`, so a symlink cannot masquerade), owned by
   root, not writable by group or others.
3. **Version and compiled features** from `--version`: DHCP present; TFTP, DHCPv6, auth,
   dumpfile, and scripts absent.

`NO_SCRIPT` matters most: without it, a dnsmasq directive can name a program to run on every
lease event, inside a process that started as root. Compiling it out closes that permanently
rather than relying on the generator never emitting the directive.

Ticket §21.3 asks instead for a SHA-256 recomputed against a compile-time constant. That is not
constructible — `codesign` writes the signature into the Mach-O, and the helper is compiled
before dnsmasq is signed. `RISKS.md` R-13 records the substitution and why it is stronger.

## 4. Injection

Every value that reaches a generated file passes a validator first, and the validators are
allow-lists rather than deny-lists — a deny-list has to anticipate every dangerous character,
an allow-list only has to name the safe ones.

- **Host names and domains**: lowercase letters, digits, hyphens, dots. Rejects newlines (which
  would start a new directive), `#` (which would comment out the rest of the line), commas
  (which separate values within a directive), and shell metacharacters.
- **IPv4 addresses**: `inet_pton`, plus an explicit rejection of leading zeros. macOS's own
  `inet_pton` accepts `010.1.1.1` as decimal 10 while many parsers read it as octal 8 — an
  address two parsers disagree about must not reach a config file.
- **Interface names**: `^[a-z][a-z0-9]{0,15}$`, plus a blocklist of families macOS manages.
- **Record comments**: unrestricted, and safe precisely because they are written to neither the
  config nor the hosts file. A golden test keeps that true.

The malicious inputs named in ticket §24.1 are covered in `SecurityInputTests`.

## 5. Not damaging the wrong network

Layered, and enforced in the helper rather than only in the UI:

- Wi-Fi is permanently barred from DHCP in v0.1, decided by SystemConfiguration's interface
  type — never by name, because `en0` is Wi-Fi on a laptop and Ethernet on a Mac mini.
- The current default-route interface is barred.
- Loopback, VPN, bridge, AWDL, and utun are barred.
- An explicit isolation confirmation is required. It is never persisted, and resets on stop, on
  interface change, and on any pool change.
- dnsmasq is pinned with `interface=` and `bind-interfaces`.
- UDP 67 is probed at preflight and **again** after the alias is added, because the first answer
  is already stale.

No software can tell an isolated lab switch from a production one. The confirmation is the last
line of defence, and it is deliberately unskippable.

## 6. Privacy

Logs contain IP addresses, MAC addresses, host names, and client identifiers. They stay on the
machine. There is no analytics SDK, no crash reporter, no telemetry, and no network call at
runtime other than dnsmasq's own DNS forwarding. Export writes only where the user picks, and
the save panel says so.

## 7. Files

```
/var/db/com.bee.macnetlab/            root:wheel 0750
├── active-session.json               root:wheel 0600
├── lock                              root:wheel 0600
└── sessions/<uuid>/                  root:nobody 0750
    ├── dnsmasq.conf                  root:wheel  0644
    ├── hosts                         root:wheel  0644
    ├── dnsmasq.leases                nobody:nobody 0640
    ├── dnsmasq.log                   nobody:nobody 0640
    └── dnsmasq.pid                   nobody:nobody 0640
```

The three files dnsmasq writes are **pre-created** owned by `nobody`, inside a directory that
stays unwritable by it. The dropped-privilege process can therefore write its own files and
create nothing.

Profiles live in `~/Library/Application Support/` and are written by the app only. Ticket §20.1
forbids the root helper from writing user data.

## 8. Signalling a process

Before any signal, the helper confirms the PID is still the process it launched: greater than 1,
alive, `proc_pidpath` resolving to our bundled dnsmasq, and the executable's digest matching what
was recorded at launch.

If identity cannot be established, **nothing is sent** and a stale session is reported. A root
process signalling a recycled PID would kill whatever the user happens to be running.

## 9. Known gaps

`RISKS.md` is the authority. The security-relevant entries are R-01 (no Developer ID, so no
notarized distribution), R-03 (caller validation is the single boundary), R-12 (the dnsmasq
signing key's provenance is asserted, not independently established), and R-13 (the engine
verification substitution).
