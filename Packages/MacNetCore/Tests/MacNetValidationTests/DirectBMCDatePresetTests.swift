import Foundation
import Testing
import MacNetModels
import MacNetValidation

@Suite("Direct BMC date preset")
struct DirectBMCDatePresetTests {
    private func calendar(secondsFromGMT: Int = 0) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: secondsFromGMT)!
        return calendar
    }

    private func date(month: Int = 10, day: Int, hour: Int = 12) -> Date {
        calendar().date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test("uses 100 plus the day and preserves the configured subnet",
          arguments: [(1, "192.168.1.101"), (30, "192.168.1.130"), (31, "192.168.1.131")])
    func dailyAddress(day: Int, expectedAddress: String) throws {
        let profile = ProfileFixture.make(serverIPv4: "192.168.1.29",
                                          rangeStart: "192.168.1.30", rangeEnd: "192.168.1.200")
        let preset = try #require(DirectBMCDatePreset.applying(
            to: profile, on: date(day: day), calendar: calendar()
        ))
        #expect(preset.dhcpConfiguration.rangeStart.description == expectedAddress)
        #expect(preset.dhcpConfiguration.rangeEnd == preset.dhcpConfiguration.rangeStart)
        #expect(preset.dhcpConfiguration.poolSize == 1)
        #expect(ConfigurationValidator.validate(preset).isEmpty)
    }

    @Test("uses the local day at a UTC date boundary")
    func localDateBoundary() throws {
        let preset = try #require(DirectBMCDatePreset.applying(
            to: ProfileFixture.make(), on: date(day: 29, hour: 16),
            calendar: calendar(secondsFromGMT: 9 * 3_600)
        ))
        #expect(preset.dhcpConfiguration.rangeStart.description == "192.168.50.130")
    }

    @Test("keeps the subnet across a month boundary")
    func monthBoundary() throws {
        let preset = try #require(DirectBMCDatePreset.applying(
            to: ProfileFixture.make(), on: date(month: 10, day: 1), calendar: calendar()
        ))
        #expect(preset.dhcpConfiguration.rangeStart.description == "192.168.50.101")
    }

    @Test("changes only the two pool endpoints")
    func preservesOtherSettings() throws {
        let profile = ProfileFixture.make(leaseSeconds: 600)
        let preset = try #require(DirectBMCDatePreset.applying(
            to: profile, on: date(day: 30), calendar: calendar()
        ))
        var expected = profile
        expected.dhcpConfiguration.rangeStart = IPv4Address("192.168.50.130")!
        expected.dhcpConfiguration.rangeEnd = IPv4Address("192.168.50.130")!
        #expect(preset == expected)
        #expect(profile.dhcpConfiguration.rangeStart.description == "192.168.50.10")
    }

    @Test("does not offer the Mac's own address")
    func rejectsMacConflict() {
        let profile = ProfileFixture.make(serverIPv4: "192.168.50.130")
        #expect(DirectBMCDatePreset.applying(to: profile, on: date(day: 30),
                                           calendar: calendar()) == nil)
    }

    @Test("does not offer an advertised router's address")
    func rejectsRouterConflict() {
        let profile = ProfileFixture.make(advertiseRouter: true, routerIPv4: "192.168.50.130")
        #expect(DirectBMCDatePreset.applying(to: profile, on: date(day: 30),
                                           calendar: calendar()) == nil)
    }

    @Test("requires an enabled DHCP service on a private /24 subnet")
    func rejectsUnsupportedConfiguration() {
        for profile in [
            ProfileFixture.make(prefixLength: 25),
            ProfileFixture.make(serverIPv4: "8.8.8.1"),
            ProfileFixture.make(dhcpEnabled: false),
        ] {
            #expect(DirectBMCDatePreset.applying(to: profile, on: date(day: 30),
                                               calendar: calendar()) == nil)
        }
    }
}
