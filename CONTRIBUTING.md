# Contributing

Patches and bug reports are welcome. Read this first — the rules below are not style
preferences. Most of them exist because this product runs privileged code on someone's
machine, and misbehaves in a datacenter if it is wrong.

## Non-negotiables

1. **The app is never root.** Every privileged action goes through the helper over XPC.
2. **The helper takes no arbitrary input.** No command strings, no executable paths, no file
   paths from the app. Only structured, versioned, validated payloads.
3. **Never use a shell to run anything.** `Process.executableURL` plus an argument array,
   always. No `/bin/sh -c`, no `bash -c`, no string interpolation into commands.
4. **Validate twice.** The app validates for fast feedback; the helper re-validates
   everything from scratch. Helper-side validation is the real security boundary — never
   skip it because "the app already checked".
5. **Do not touch the system's configuration.** Not `/etc/hosts`, not `/etc/dnsmasq.conf`,
   and no permanent change to any macOS network service. Only a temporary IPv4 alias that is
   removed on stop.
6. **Every side effect is journalled before and after it happens**, and every failure path
   rolls back in reverse order. An alias that leaks is a bug, not an edge case.
7. **No telemetry, analytics, crash reporting, or network calls at runtime.** Logs stay on
   the machine.

## Scope

v0.1 is deliberately small: one interface, one subnet, DHCPv4 and DNS, started and stopped
by hand. Several obvious features are left out on purpose — IPv6, multiple simultaneous
interfaces, PXE/TFTP, and anything that would need the app to keep running in the
background. If something seems missing, it probably is, and probably for a reason.

Open an issue before building a large feature, so the discussion happens before the work
rather than after it.

## Code

- Swift 6 language mode with complete strict-concurrency checking. Shared mutable state goes
  in an `actor`.
- No `!` force unwraps. No `try!`. Warnings are errors.
- Source comments and log messages are English. User-facing strings live in the string
  catalog, never inline in a view.
- Anything that can be a pure function should be: the dnsmasq config generator in particular
  must not touch the file system, so that it is exhaustively testable.
- Comments explain *why*. What the code does is already on the screen.

## Project structure

`project.yml` is the source of truth for the Xcode project. `DnsmasqForMac.xcodeproj` is
generated and is not committed — run `make generate`, never edit `project.pbxproj`.

Identifiers live only in `Config/Identifiers.xcconfig`. Swift reads them through Info.plist;
shell scripts read them through `Scripts/lib-identifiers.sh`. Do not hardcode a bundle ID, a
Mach service name, or a Team ID anywhere else.

`DEVELOPMENT_TEAM` in that file is the author's Team ID. Replace it with your own to build a
signed copy; the helper authenticates its caller against it, so a stale value makes the app
unable to talk to its own helper.

## Tests

- `make test` must stay green and must not require human input.
- A failing test is fixed by fixing the cause. Deleting the test, skipping it, or weakening
  the assertion is never an acceptable resolution.
- The malicious-input suites are load-bearing. Add to them when you add a new input path.
- Anything that needs real hardware belongs in `Docs/MANUAL_TEST_PLAN.md`, not in a test
  that quietly passes because it never ran.

## Before you open a pull request

```bash
make generate
make build
make test
```

and `make verify-bundle` as well if you touched the helper, the bundle layout, or dnsmasq.

Known-unsettled things are recorded in `Docs/RISKS.md`. If you hit one, add to it rather
than working around it silently.
