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
}
