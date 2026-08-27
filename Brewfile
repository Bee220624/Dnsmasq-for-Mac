# Development tooling only.
#
# Nothing here is a runtime dependency of the shipped app. Scripts/verify-bundle.sh fails
# the build if any Homebrew path leaks into a distributed binary (ticket §3.2, §22.3).

# Generates DnsmasqForMac.xcodeproj from project.yml.
brew "xcodegen"

# Source formatting for Swift. Optional; `make build` does not depend on it.
brew "swift-format"

# Used by Scripts/build-dnsmasq.sh to verify the upstream source signature.
brew "gnupg"
