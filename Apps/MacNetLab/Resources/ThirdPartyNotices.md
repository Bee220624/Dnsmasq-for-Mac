# Third-Party Notices

MacNetLab bundles the following third-party software.

## dnsmasq

- Upstream: <https://thekelleys.org.uk/dnsmasq/>
- Version: see `Resources/ThirdParty/dnsmasq/VERSION`
- Copyright © Simon Kelley
- Licence: GNU General Public License, version 2 **or** version 3

dnsmasq is bundled as a **separate, unmodified executable**. No dnsmasq source or object
code is compiled or linked into any MacNetLab binary; MacNetLab controls it purely by
writing a configuration file and managing the process.

The full licence texts travel inside the application bundle, as `COPYING` (GPL v2) and
`COPYING-v3` (GPL v3) in `Contents/Resources`, and can be opened from Settings → Licenses.

The corresponding source is not merely cited. Every release is packaged with the exact
upstream source archive, the digest it was verified against, and `Scripts/build-dnsmasq.sh` —
the script that produced the bundled binary, including its compile options. Any patches
applied would live in `Resources/ThirdParty/dnsmasq/patches/` with a written rationale; as of
v0.1 there are none.
