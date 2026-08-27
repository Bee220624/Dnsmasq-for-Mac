# Vendored dnsmasq

Dnsmasq for Mac ships dnsmasq as a **separate, unmodified executable**. No dnsmasq source or object
code is compiled or linked into any Dnsmasq for Mac binary; the app controls it purely by writing a
configuration file and managing the process (ticket §23).

## What is in this directory

| File | Purpose |
|---|---|
| `VERSION` | The pinned upstream version. The build script reads this; the version is not written anywhere else. |
| `SOURCE_URL` | Exact upstream archive the build fetches. |
| `SHA256SUMS` | Digest of that archive, verified on every build. |
| `SIGNING_KEY_FINGERPRINT` | OpenPGP key the upstream signature must be made by. |
| `COPYING` | GPL v2, as shipped by upstream. |
| `COPYING-v3` | GPL v3, as shipped by upstream. |
| `BINARY_SHA256` | Digest of the built Universal 2 binary, written by the build and checked by the helper before every launch. |
| `source/` | The downloaded archive and expanded tree. Not committed — reproduced by `make vendor-dnsmasq`. |

## Why the version is pinned

Ticket §3.4 forbids tracking `latest` and forbids downloading anything at app runtime. dnsmasq
is a network service running as root on an engineer's machine; which exact build ships is a
decision that gets reviewed, not one that drifts. Upgrading is its own ticket.

## Trust model

Two independent checks, both of which must pass:

1. **Digest.** The archive must match `SHA256SUMS`. This catches any change to the artefact we
   vetted, whatever its cause.
2. **Signature.** The archive's detached OpenPGP signature must verify, *and* the signing key
   must be the fingerprint in `SIGNING_KEY_FINGERPRINT`.

The fingerprint check is the part that matters. Fetching a key from a keyserver and trusting
it because it signed the file would be circular; pinning the fingerprint means a compromised
keyserver produces a build failure rather than a silent substitution.

> **Owner action.** The fingerprint recorded here was taken from the signature on the 2.93
> archive and corresponds to `Simon Kelley <simon@thekelleys.org.uk>` /
> `<srk@debian.org>`. Before any public release, corroborate it against an independent source
> — the Debian keyring is the natural one, since the same person maintains dnsmasq there. See
> `Docs/RISKS.md` R-12.

## Reproducing the build

```bash
make vendor-dnsmasq
```

The procedure, the compile options, and what is verified afterwards are documented in
`Docs/DNSMASQ_BUILD.md`.

## Patches

None. If one ever becomes necessary it goes in `patches/` with a written rationale, is applied
by the build script rather than by editing the extracted tree, and is retained for
distribution alongside the source (ticket §22.1, §23).
