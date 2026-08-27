# Building the bundled dnsmasq

Dnsmasq for Mac ships its own dnsmasq. It is never downloaded at runtime, never fetched from
Homebrew, and never tracks `latest` — which dnsmasq ships is a decision that gets reviewed
(ticket §3.4).

```bash
make vendor-dnsmasq
```

---

## 1. What is pinned, and where

Everything about the vendored build is data in `Resources/ThirdParty/dnsmasq/`, so an upgrade
is an edit to those files plus a re-run, reviewable as a diff:

| File | Contents |
|---|---|
| `VERSION` | `2.93` |
| `SOURCE_URL` | `https://thekelleys.org.uk/dnsmasq/dnsmasq-2.93.tar.xz` |
| `SHA256SUMS` | Digest of that archive |
| `SIGNING_KEY_FINGERPRINT` | OpenPGP key the signature must be made by |
| `BINARY_SHA256` | Digest of the built binary, written by the build |

Nothing above appears anywhere else in the codebase.

---

## 2. Verifying the source

Two independent checks, both mandatory:

**Digest.** The archive must match `SHA256SUMS`. A mismatch aborts the build and says so —
never "downloading again", never "continuing anyway".

**Signature.** The detached OpenPGP signature must verify, *and* `VALIDSIG` must name the
fingerprint in `SIGNING_KEY_FINGERPRINT`. Checking only that *some* key signed it would be
worthless: an attacker who can substitute the archive can substitute a signature too. The
fingerprint pin is what turns a compromised keyserver into a build failure.

> The fingerprint's own provenance still needs corroborating against a source independent of
> upstream — see `Docs/RISKS.md` R-12.

---

## 3. Compile options

```
-DNO_TFTP -DNO_DHCP6 -DNO_SCRIPT -DNO_AUTH -DNO_DUMPFILE -DNO_ID
```

Each removes a subsystem from the shipped binary. Code that is not compiled in cannot be
reached by a configuration mistake and cannot carry a vulnerability:

| Option | Removes | Why |
|---|---|---|
| `NO_TFTP` | File server | Out of scope until PXE is its own ticket |
| `NO_DHCP6` | DHCPv6 | v0.1 is IPv4 only |
| `NO_SCRIPT` | Lease-change hooks | dnsmasq can then never execute anything |
| `NO_AUTH` | Authoritative zone serving | This is a forwarder plus local records |
| `NO_DUMPFILE` | Packet capture | Not a capture tool |
| `NO_ID` | Chaos-class version queries | Nothing should be asking |

`NO_SCRIPT` is the one that matters most for this product: without it, a dnsmasq configuration
directive can name a program to run on every lease event, inside a process that started as
root. Compiling it out closes that door permanently rather than relying on the generator never
emitting the directive.

The resulting build reports:

```
Compile time options: IPv6 GNU-getopt no-DBus no-UBus no-i18n no-IDN DHCP no-DHCPv6
no-scripts no-TFTP no-conntrack no-ipset no-nftset no-auth no-DNSSEC no-ID loop-detect
no-inotify no-dumpfile
```

`DHCP` present and `loop-detect` present are what v0.1 needs; everything else is absent.

---

## 4. Building both architectures

Each architecture is built in its **own clean copy** of the source tree.

dnsmasq's Makefile leaves object files beside the source. Building a second architecture in
the same tree silently links whichever objects happen to be there, producing a binary that
runs on the build machine and fails everywhere else — a failure that only shows up on a
user's Mac. The build asserts `lipo -archs` on each intermediate binary to catch it
immediately if it ever happens.

The two are merged with `lipo`, and the merged binary must contain both slices.

---

## 5. What is asserted about the result

The build fails, loudly, unless all of these hold:

- Both `arm64` and `x86_64` slices are present.
- `otool -L` shows **only** system libraries. A stray `/opt/homebrew` include path is the
  usual way this breaks, and it fails only on a clean Mac, never on the machine that built it.
- `--version` reports the pinned version.
- `DHCP` is compiled in; TFTP, DHCPv6, auth, and dumpfile are not.
- `--test` accepts a minimal configuration — the same mechanism preflight uses before every
  start.

`make verify-bundle` re-asserts the architecture, linkage, signature, permissions, version,
and compile options on the copy that actually ships.

> The `x86_64` slice is cross-compiled and **cannot be executed on an Apple Silicon host**.
> Verifying it at runtime needs an Intel Mac or Rosetta. See `Docs/RISKS.md` R-07.

---

## 6. How the shipped binary is verified before launch

The helper checks the copy in the app bundle before every launch:

1. **Code signature** satisfying a requirement pinned to our Team ID — the same mechanism that
   authenticates the XPC peer.
2. **File properties**: a regular file, not a symlink, not group- or world-writable.
3. **Version**, from `--version`.

Ticket §21.3 asks instead for a recomputed SHA-256 against a compile-time constant. That is
not constructible: `codesign` writes the signature into the Mach-O, so the bundled bytes
differ from the compiler's output, and the helper is compiled before dnsmasq is signed. The
checks above meet the requirement's intent. The reasoning, and what a literal implementation
would cost, is recorded in `Docs/RISKS.md` R-13.

---

## 7. Patches

There are none, and none are expected.

If one ever becomes necessary it goes in `Resources/ThirdParty/dnsmasq/patches/` with a
written rationale, is applied by the build script rather than by editing the extracted tree,
and is retained for distribution alongside the source. The vendored source is never edited in
place (ticket §22.1, §23).

---

## 8. Licence obligations

dnsmasq is GPL v2 **or** GPL v3, at the distributor's choice. Dnsmasq for Mac keeps it at arm's
length: a separate, unmodified executable, controlled through a configuration file and process
management. No dnsmasq source or object code is compiled or linked into any Dnsmasq for Mac binary.

Retained and shipped: `COPYING`, `COPYING-v3`, the exact version, the upstream source URL, the
archive digest, and this build script. Settings › Licenses surfaces them in the app.

The licence of Dnsmasq for Mac itself is **not** an implementation decision and requires legal review
before commercial distribution (ticket §23, `Docs/RISKS.md` R-06).

### The source archive is not committed

`Resources/ThirdParty/dnsmasq/source/` is gitignored: a 640 KB binary blob does not belong in
git history when the build fetches it reproducibly from a pinned URL and verifies it against a
pinned digest.

That satisfies reproducibility, but **not** the GPL's distribution obligation on its own.
Distributing the app means distributing dnsmasq, and recipients are entitled to the
corresponding source. `Scripts/package-release.sh` must therefore place the exact verified
`dnsmasq-<VERSION>.tar.xz`, this build script, and both licence texts alongside the
distributed app — not merely reference where they came from. Tracked as a release gate in
`Docs/RISKS.md` R-06.
