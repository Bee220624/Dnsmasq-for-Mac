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

The full licence texts are shipped as `COPYING` (GPL v2) and `COPYING-v3` (GPL v3), the
exact upstream source URL and archive digest are recorded under
`Resources/ThirdParty/dnsmasq/`, and the build procedure is `Scripts/build-dnsmasq.sh`.
Any patches applied would live in `Resources/ThirdParty/dnsmasq/patches/` with a written
rationale; as of v0.1 there are none.
