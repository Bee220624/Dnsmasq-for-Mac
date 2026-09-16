import MacNetModels

/// Checks address ownership and connected-subnet overlap before changing an interface.
public enum InterfaceAddressPolicy {
    public static func issues(
        configuration: InterfaceConfiguration,
        selected: NetworkInterfaceDescriptor,
        interfaces: [NetworkInterfaceDescriptor]
    ) -> [PreflightIssue] {
        var issues: [PreflightIssue] = []
        let address = configuration.serverIPv4
        if let existing = selected.existingEntry(for: address) {
            if existing.prefixLength != configuration.prefixLength {
                issues.append(PreflightIssue(
                    id: "interface.addressPrefixConflict", severity: .error,
                    title: "Address Already Configured Differently",
                    message: "\(address) already has a different subnet mask on \(selected.bsdName).",
                    recoverySuggestion: "Choose another Mac address with the intended subnet mask."
                ))
            }
        } else if !configuration.addTemporaryIPv4Alias {
            issues.append(PreflightIssue(
                id: "interface.addressMissing", severity: .error,
                title: "Mac Address Is Missing",
                message: "\(address) is not configured on \(selected.bsdName).",
                recoverySuggestion: "Enable the temporary IPv4 address option."
            ))
        }
        guard let subnet = configuration.subnet else { return issues }
        for other in interfaces where other.bsdName != selected.bsdName && other.isUp {
            let overlaps = other.ipv4Addresses.contains { entry in
                guard let prefix = entry.prefixLength,
                      let otherSubnet = IPv4Subnet(containing: entry.address, prefixLength: prefix)
                else { return entry.address == address }
                return subnet.contains(otherSubnet.networkAddress) || otherSubnet.contains(subnet.networkAddress)
            }
            if overlaps {
                issues.append(PreflightIssue(
                    id: "interface.subnetOverlap.\(other.bsdName)", severity: .error,
                    title: "Subnet Already Used By Another Interface",
                    message: "The device subnet overlaps an address on \(other.displayName) (\(other.bsdName)). Traffic to the BMC may use the wrong adapter.",
                    recoverySuggestion: "Choose a different device subnet, or disconnect the conflicting network before starting."
                ))
            }
        }
        return issues
    }
}
