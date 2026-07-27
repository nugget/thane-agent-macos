import Foundation
import Testing
@testable import thane_agent_macos

struct AppPresentationTests {
    @Test
    func configurationModesUseUserFacingConcepts() {
        #expect(AgentConfigurationMode.allCases.map(\.title) == ["Managed", "Advanced"])
        #expect(AgentConfigurationMode.managed.detail.contains("supervised"))
        #expect(AgentConfigurationMode.advanced.detail.contains("operate yourself"))
    }

    @Test
    func aboutVersionUsesStandardMacPhrasingWithFullProvenance() {
        #expect(
            AppVersion.formatAboutVersion(
                current: "v1.4.0-3-gabc1234",
                build: "42"
            ) == "Version v1.4.0-3-gabc1234 (42)"
        )
    }

    @Test
    func iconOnlyDoesNotInjectMenuBarText() {
        #expect(MenuBarTextStyle.iconOnly.text(status: "Ready", version: "v1.4.0") == nil)
    }

    @Test
    func statusAndVersionComposeCompactly() {
        #expect(
            MenuBarTextStyle.statusAndVersion.text(
                status: "Ready",
                version: "v1.4.0"
            ) == "Ready · v1.4.0"
        )
    }

    @Test
    func versionStyleFallsBackToStatusForAdvancedConnections() {
        #expect(
            MenuBarTextStyle.version.text(
                status: "Connecting…",
                version: nil
            ) == "Connecting…"
        )
    }

    @Test
    func advancedConnectionReusesOnlyAnExactActiveSelection() {
        let url = URL(string: "https://thane.example.com")!
        let active = ActiveServer(baseURL: url, token: "old-token", isLocal: false)

        #expect(
            AdvancedConnectionActivation.decide(
                activeServer: active,
                isConnected: true,
                selectedURL: url,
                selectedToken: "old-token",
                forceReconnect: false
            ) == .reuse
        )
        #expect(
            AdvancedConnectionActivation.decide(
                activeServer: active,
                isConnected: true,
                selectedURL: url,
                selectedToken: "new-token",
                forceReconnect: false
            ) == .connect
        )
    }

    @Test
    func explicitReconnectNeverReusesAnActiveConnection() {
        let url = URL(string: "https://thane.example.com")!
        let active = ActiveServer(baseURL: url, token: "token", isLocal: false)

        #expect(
            AdvancedConnectionActivation.decide(
                activeServer: active,
                isConnected: true,
                selectedURL: url,
                selectedToken: "token",
                forceReconnect: true
            ) == .connect
        )
    }
}
