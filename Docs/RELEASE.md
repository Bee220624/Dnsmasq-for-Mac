# Release

> **Status: blocked.** This machine has an Apple Development certificate but no
> **Developer ID Application** certificate, and no notarization credentials. The procedure below
> is complete and the scripts run end to end on a machine that has them. See `RISKS.md` R-01.

## What a release requires

| Requirement | Status here |
|---|---|
| Developer ID Application certificate | **missing** |
| notarytool keychain profile | **missing** |
| Vendored dnsmasq, Universal 2 | present |
| Hardened runtime | enabled |
| Manual test plan completed on macOS 14 | not run |
| GPL source materials | present, packaged by the script |

## Procedure

```bash
make vendor-dnsmasq          # once per dnsmasq version
Scripts/build-release.sh     # Universal 2, signed inside-out, verified
Scripts/package-release.sh   # notarize, staple, archive, + GPL source bundle
```

`build-release.sh` checks for the certificate **before** building, so a missing one costs a
second rather than a full build.

### Signing order

Nested code is signed before the bundle containing it:

1. `Contents/Library/HelperTools/dnsmasq`
2. `Contents/Library/HelperTools/com.bee.dnsmasqformac.helper`
3. `DnsmasqForMac.app` (with entitlements)

Signing the outer bundle first would be invalidated by every inner signature that followed.

### Notarization

```bash
xcrun notarytool store-credentials Dnsmasq for Mac \
    --apple-id <your-apple-id> --team-id MDUMXF88CA --password <app-specific-password>
```

Stored in the keychain, never in this repository. `.gitignore` refuses `*.p12`, `*.cer`,
`*.mobileprovision`, and `notary-credentials*`.

The ticket is stapled to the `.app` and the archive is then rebuilt. Stapling the zip would lose
the ticket the moment the user expanded it, which defeats the point on an offline machine.

## GPL obligations

Distributing the app distributes dnsmasq, so `package-release.sh` produces a second archive
containing the verified upstream source, both licence texts, the version and digest, and
`build-dnsmasq.sh`. **Both archives must be published together.** Reproducibility is not the
same obligation as distribution: the source has to travel with the binary, not merely be cited.

> The final licence of Dnsmasq for Mac itself is not an implementation decision and requires legal
> review before any commercial distribution (`RISKS.md` R-06). `LICENSE_PENDING` is
> intentional.

## Before publishing

- [ ] `make test` green
- [ ] `make verify-bundle` green against the **Release** bundle
- [ ] `Docs/MANUAL_TEST_PLAN.md` completed on a clean macOS 14 machine
- [ ] `spctl --assess --type execute` accepts the stapled app
- [ ] The x86_64 slice exercised on an Intel Mac or under Rosetta (`RISKS.md` R-07)
- [ ] dnsmasq confirmed to run as `nobody`, not root (`RISKS.md` R-08)
- [ ] The dnsmasq signing key corroborated against an independent source (`RISKS.md` R-12)
- [ ] `git status --short` clean; no certificates, passwords, or notary tokens in the tree
